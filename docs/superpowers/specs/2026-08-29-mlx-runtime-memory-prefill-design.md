# MLX 运行时内存与 Prefill 优化设计

日期：2026-08-29  
状态：设计已确认，待拆分实施计划

## 1. 目标与边界

目标是在 M1、16 GB 统一内存的 Mac 上，让 Stable Diffusion、MusicGen、MiniMax H3 和文本 LLM 优先稳定运行，再降低内存占用并改善文本 LLM 的 prefill 速度。

本次默认保持现有生成质量和公开调用接口，不用降低扩散步数或强制截断上下文来换取内存。用户明确要求不记录以下运行时指标，因此不增加性能埋点、持久化统计或 OOM/cache 错误统计：

- 首次加载内存和峰值内存
- prefill、decode 或采样耗时
- OOM 或 cache 错误发生次数

开发验证可以进行一次性本地观察，用于选择默认参数，但结果不写入应用数据、日志系统或长期文件。

## 2. 现状问题

### 2.1 KVCacheManager

当前实现将生成期间仍会变化的原始 cache 直接放入 `NSCache`，可能导致下次请求读到被追加过的状态。磁盘格式只保存每层的 K/V，不能完整恢复 `RotatingKVCache`、`QuantizedKVCache`、`ChunkedKVCache` 的类型、offset 和 meta state；同时缺少模型/模板指纹、并发保护、原子写入、按字节淘汰，以及清理内存项的逻辑。

MLXLMCommon 已提供 `KVCache` 的复制和元数据能力，以及 `savePromptCache` / `loadPromptCache`。统一管理器应直接使用这些能力，而不是继续维护一个只认识两数组的私有格式。

### 2.2 模型生命周期

Stable Diffusion、MusicGen、LTX 和 H3 目前分别修改全局 MLX 内存限制；H3 会长期保留多个 VAE、encoder 和 transformer；Stable Diffusion 的 `conserveMemory` 通过把 steps 设为 1 换内存。这些策略在统一内存设备上会相互干扰，也会牺牲质量。

### 2.3 模型适用性

文本 LLM 的自回归 self-attention 适合 KVCache。MusicGen 的 decoder self-attention 也有可复用的增量 cache，但 cross-attention 的文本 K/V 可以进一步静态缓存。Stable Diffusion 的 UNet 和 H3 的扩散 self-attention 每一步都处理变化的 latent，不能直接套用自回归 KVCache；强行复用会改变结果或产生错误。

## 3. 总体架构

新增一个进程内的 `InferenceRuntimeCoordinator`（actor），负责重模型任务的准入、阶段切换和释放；将 `KVCacheManager` 改成独立的、并发安全的 prompt cache 存储层。

### 3.1 运行时协调器

- 以 workload/stage 申请一次性 lease，默认只允许一个重模型阶段同时驻留。
- 统一执行阶段结束时的模型引用释放、MLX cache 清理和取消收尾。
- 工厂不再各自写入 `Memory.cacheLimit` 和 `Memory.memoryLimit`；内存策略集中在 coordinator 的 16 GB 保守 profile 中。
- coordinator 只负责准入和生命周期，不记录性能或错误统计。
- 轻量的 tokenization、参数校验和文件检查不需要占用重模型 lease。

### 3.2 借鉴 vLLM/DeepSpeed 的部分

只借鉴适合 MLX/Apple Silicon 的思想：精确前缀复用、分块 prefill、按成本淘汰、准入控制、阶段性 offload/release。不会直接移植 CUDA PagedAttention、GPU page allocator 或 ZeRO 内核；MLX 的 cache 数组和 M1 统一内存不具备这些实现的前提。

## 4. KVCacheManager 设计

### 4.1 缓存内容

内存和磁盘都保存完整的 prompt cache 快照，使用 MLXLMCommon 的 `savePromptCache` / `loadPromptCache`，保留：

- cache 类型
- 每层 state
- offset
- meta state
- MLX 需要的元数据

写入前对传入 cache 做 `copy()`，绝不把生成过程中的可变实例直接放入内存缓存。读取后再复制到本次请求的工作 cache，避免请求之间共享可变状态。

### 4.2 Key 与兼容性

缓存 key 由以下信息组成：模型标识和权重版本、tokenizer 标识、system prompt、工具定义、消息模板版本、已完成前缀 token 序列、cache 相关参数和应用 cache 格式版本。任何 shape、层数、offset 或 metadata 不匹配都视为 miss，并安全地重新 prefill。

文件名使用经过编码的 digest，不直接使用用户输入作为路径。磁盘写入使用临时文件后原子替换；加载和淘汰由 actor 串行化。

### 4.3 淘汰与清理

使用按实际字节数估算的 LRU，而不是固定条目数。清理操作同时移除内存快照和磁盘文件；损坏文件、版本过期文件或读取失败只触发删除和重新计算，不影响主请求。

保留现有 `save`、`load`、`clear` 的调用语义，先以兼容包装迁移 `LMService`，避免一次改动扩散到其他模型。

## 5. 文本 LLM Prefill 设计

### 5.1 精确前缀复用

在 `LMService` 中只缓存完全一致的 system/tool/history 前缀。最后一条用户消息、尚未执行的工具调用和采样参数不进入可复用前缀。命中后从快照复制 cache，再只对新增 token 执行 prefill。

### 5.2 分块 Prefill

将 `GenerateParameters.prefillStepSize` 的默认值调整到适合 16 GB 设备的 128/256 token 区间，并保留显式配置入口。默认不强制 `maxKVSize`，以免改变长上下文语义；需要低内存模式时再启用 `RotatingKVCache`，并明确这是可选的上下文窗口折衷。

### 5.3 KV 量化能力探测

`kvBits` 不全局开启。只有模型的 attention 实现明确支持 `QuantizedKVCacheProtocol` 时才允许量化；不支持的模型、恢复失败或 shape 不一致时自动回退到普通 `KVCacheSimple`。量化失败不能让请求崩溃。

### 5.4 取消与失败

prefill、读取 cache 和生成被取消时，临时 cache 不写入共享存储。工具调用、模板改变或模型切换时使用新的 key，避免跨会话污染。

## 6. MusicGen 设计

- 保留 decoder self-attention 的增量 cache，但改为明确的请求级工作状态，不跨请求共享可变实例。
- 对每个 decoder layer 缓存 cross-attention 的文本 K/V 投影；同一请求的每个音频 token 复用它们。
- 预分配目标音频序列，减少循环中的数组重建和不必要的拷贝。
- 文本 conditioner 完成后，在进入长音频生成阶段释放不再需要的对象。
- 不改变 codebook 数量、采样策略或音频输出接口。

## 7. Stable Diffusion 设计

- 不引入自回归 KVCache；保留当前 UNet denoise 语义。
- 文本 embedding 在一次请求内复用。
- 将 text encoder、UNet、VAE 组织为明确的阶段：完成某阶段后释放引用并清理 MLX cache，再进入下一阶段。
- 用阶段性释放替代 `steps = 1` 的质量破坏策略；默认 steps 保持调用方设置。
- 保留 decoder detach/低内存入口，但让它由 coordinator 管理，避免与其他工厂的全局设置冲突。

## 8. MiniMax H3 设计

- 不将传统自回归 KVCache 用于完整 H3 扩散 self-attention，因为 latent 在每个采样步变化且 attention 不是因果的。
- 缓存 `prepareRender` 产生的静态文本/条件投影和位置相关数据。
- 将 tokenizer/text encoder、visual/audio VAE、omni transformer 分成可释放阶段；采样期间只保留必要组件。
- 保持现有 FL2VA 输入模式、尺寸约束、时长和采样接口。
- 先修复当前工作区中的 loader/config 编译阻断，再做驻留优化，避免在不稳定基线上叠加内存改动。

## 9. 实施顺序

1. 只修复当前明确的编译/配置阻断，并完成四类模型的最小 smoke path。
2. 实现 coordinator 和统一内存 profile，迁移各模型工厂的全局内存设置。
3. 重写 `KVCacheManager`，接入 MLX prompt-cache 序列化和精确前缀复用。
4. 优化文本 LLM prefill，并加入兼容性探测的可选 KV 量化/滑动窗口。
5. 优化 MusicGen cross-attention cache 和请求内预分配。
6. 优化 Stable Diffusion/H3 的阶段性驻留和释放。
7. 做构建、cache 正确性、取消/失败回退和四个 backend 的手动 smoke 验证；不加入运行时指标记录。

## 10. 验收标准

- 现有四类模型接口不变，默认生成质量和采样步数不变。
- 16 GB M1 profile 下不因多个工厂互相覆盖全局内存策略而失控。
- prompt cache 能正确区分模型、模板和前缀，命中后不会出现 offset 累加或跨请求污染。
- 不兼容量化 cache 的模型能够自动回退，不因尝试量化而崩溃。
- MusicGen、Stable Diffusion、H3 的阶段释放不会访问已释放对象。
- 不新增首次加载内存、峰值内存、耗时、OOM 或 cache 错误的运行时记录。
- 编译和基本生成路径通过，失败时有安全回退而不是静默返回错误结果。

## 11. 风险与回退

- 某些 MLX 模型不支持量化 cache：保持普通 cache，功能优先。
- 长上下文在 16 GB 设备上仍可能超出预算：默认不截断；由显式低内存 profile 选择滑动窗口。
- H3/SD 的阶段释放若遇到 MLX 延迟执行引用未释放：退回更保守的阶段边界，并只清理已确认无引用的组件。
- 当前用户工作区有未提交改动：所有实现只修改任务相关文件，不回滚或覆盖其他改动。
