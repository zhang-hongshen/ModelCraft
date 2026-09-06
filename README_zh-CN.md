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

ModelCraft 将本地语言模型与媒体生成模型整合到一款原生应用中，支持 macOS。你可以与模型对话、使用项目整理工作、把文件作为上下文，并让助手通过工具完成多步骤任务。

<!-- 截图：浅色与深色模式下，展示多步骤工具任务的主对话界面。 -->

## ModelCraft 可以做什么

- **本地模型对话：** 直接浏览、下载和切换受支持的模型，无需另外配置推理服务器。
- **多模态输入：** 在同一次对话中使用文字、语音输入、图片、文档和音频。
- **项目与文档上下文：** 将相关对话和文件集中到项目中，让助手在回答时检索项目文档。
- **Agent 工作流：** 通过可用工具，让助手处理文件、运行命令、读取网页并与屏幕交互。
- **本地媒体创作：** 使用受支持的模型生成图片、音频、音乐和视频，并在对话中查看结果。
- **上下文管理：** 查看上下文使用情况，并在长对话中按需压缩上下文。

<!-- 截图：项目与文档上下文。 -->

<!-- 截图：模型商店与模型下载管理。 -->

## 开始使用

### 系统要求

- macOS 15 或更高版本

### 安装发布版本

前往 [GitHub Releases](https://github.com/zhang-hongshen/ModelCraft/releases) 下载最新可用版本。打开 ModelCraft，在模型商店中下载兼容模型，即可开始对话。

### 从源码构建

1. 克隆此仓库。
2. 使用 Xcode 打开 `ModelCraft.xcodeproj`。
3. 选择 ModelCraft scheme 和 macOS 目标设备。
4. 构建并运行应用。Xcode 会解析项目声明的 Swift Package 依赖。

## 工作方式

ModelCraft 直接在设备上运行受支持的模型。一次对话既可以是简单的本地聊天，也可以成为 Agent 工作流：添加上下文、启用希望提供给模型的工具，让模型随着任务推进，根据工具描述选择合适的能力。

项目为相关对话和文档提供持续使用的工作空间。涉及文件、命令或屏幕交互的任务可以使用系统能力。

## 隐私与网络访问

本地推理和对话数据保留在你的设备上。模型下载、网页访问以及其他由你明确连接的功能需要网络，并可能向你选择使用的服务发送请求。

## 文档与贡献

- 阅读[项目文档](https://deepwiki.com/zhang-hongshen/ModelCraft)。
- 通过 [GitHub Issues](https://github.com/zhang-hongshen/ModelCraft/issues) 报告问题或提出功能建议。
- 欢迎贡献代码。较大的改动建议先创建 Issue，讨论并确认范围。

## 许可证

ModelCraft 使用 [MIT License](./LICENSE) 开源。
