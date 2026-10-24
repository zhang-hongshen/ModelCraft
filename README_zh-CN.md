<div align="center">
  <img alt="ModelCraft" height="200" src="./logo.png" />

  <p><strong>面向 macOS、本地优先的开源 AI 助手。</strong></p>

  <p>
    <a href="README.md"><img alt="English" src="https://img.shields.io/badge/lang-English-blue.svg" /></a>
    <a href="https://github.com/zhang-hongshen/ModelCraft/releases"><img alt="Release" src="https://img.shields.io/github/v/release/zhang-hongshen/ModelCraft?display_name=tag" /></a>
    <a href="https://github.com/zhang-hongshen/ModelCraft/blob/master/LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-f5de53" /></a>
    <a href="https://deepwiki.com/zhang-hongshen/ModelCraft"><img alt="Documentation" src="https://img.shields.io/badge/docs-DeepWiki-blue" /></a>
  </p>
</div>

ModelCraft 将本地语言模型与媒体生成模型整合到一款原生应用中，支持 macOS。你可以与模型对话、使用项目整理工作、把文件作为上下文、连接 Mac 上的应用、安排定时任务，并让助手通过工具完成多步骤任务。

<picture>
  <source media="(prefers-color-scheme: light)" srcset="Screenshots/chat.png" />
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/chat-dark.png" />
  <img alt="ModelCraft 多步骤工具任务对话" src="Screenshots/chat.png" />
</picture>

## ModelCraft 可以做什么

- **本地模型对话：** 直接浏览、下载和切换受支持的模型，无需另外配置推理服务器。后续对话复用提示词缓存；DeepSeek V4 Flash 等大型混合专家模型在内存不足时可从磁盘按需读取专家权重。
- **多模态输入：** 在同一次对话中使用文字、语音输入、图片、文档和音频。
- **项目与文档上下文：** 将相关对话和文件集中到项目中，让助手在回答时检索项目文档。
- **Agent 工作流：** 通过可用工具，让助手处理文件、运行命令、读取网页、使用备忘录、日历、提醒事项和邮件，并与屏幕交互。不常用的工具按需加载，让每次请求保持精简。
- **连接器：** 安装配套的 Mac 应用（Arthub、Cellar、Keel、TuneStudio）后，助手可以通过 MCP 工具读取和操作这些应用中的数据，任何修改都需要你批准。
- **定时任务：** 让提示词执行一次，或按每小时、每天、每周、每月、每年重复执行。规则可以按工作日和法定节假日（含调休）安排，每次运行都会创建新对话，并可在完成时通知你。
- **本地媒体创作：** 使用受支持的模型生成图片、音频、音乐和视频，并在对话中查看结果。
- **上下文管理：** 查看上下文使用情况，并在长对话中按需压缩上下文。

<table>
  <tr>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/model-store.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/model-store-dark.png" />
        <img alt="模型商店" src="Screenshots/model-store.png" />
      </picture>
      <br /><sub>模型商店</sub>
    </td>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/connectors.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connectors-dark.png" />
        <img alt="连接器" src="Screenshots/connectors.png" />
      </picture>
      <br /><sub>连接器</sub>
    </td>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/scheduled-tasks.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/scheduled-tasks-dark.png" />
        <img alt="定时任务" src="Screenshots/scheduled-tasks.png" />
      </picture>
      <br /><sub>定时任务</sub>
    </td>
  </tr>
</table>

## 开始使用

### 系统要求

- macOS 15 或更高版本

### 安装发布版本

前往 [GitHub Releases](https://github.com/zhang-hongshen/ModelCraft/releases) 下载最新可用版本。打开 `ModelCraft_<版本号>.dmg`，将 ModelCraft 拖入「应用程序」，然后打开 ModelCraft，在模型商店中下载兼容模型，即可开始对话。

发布版本使用 ad-hoc 签名，未经过 Apple 公证，因此首次打开会被 macOS 拦截。请前往「系统设置 → 隐私与安全性」点击「仍要打开」，或运行：

```bash
xattr -cr /Applications/ModelCraft.app
```

## 文档

阅读[项目文档](https://deepwiki.com/zhang-hongshen/ModelCraft)。

## 许可证

ModelCraft 使用 [MIT License](./LICENSE) 开源。
