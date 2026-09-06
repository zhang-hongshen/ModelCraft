<div align="center">
  <img alt="ModelCraft" height="200" src="./logo.png" />

  <p><strong>A local-first, open-source AI assistant for macOS.</strong></p>

  <p>
    <a href="README_zh-CN.md"><img alt="简体中文" src="https://img.shields.io/badge/lang-简体中文-red.svg" /></a>
    <a href="https://github.com/zhang-hongshen/ModelCraft/releases"><img alt="Release" src="https://img.shields.io/github/v/release/zhang-hongshen/ModelCraft?display_name=tag" /></a>
    <a href="https://github.com/zhang-hongshen/ModelCraft/blob/master/LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-f5de53" /></a>
    <a href="https://deepwiki.com/zhang-hongshen/ModelCraft"><img alt="Documentation" src="https://img.shields.io/badge/docs-DeepWiki-blue" /></a>
  </p>
</div>

ModelCraft brings local language and media models into one native macOS app. Chat with a model, organize work into projects, provide files as context, and let the assistant use tools to complete multi-step tasks.

<!-- Screenshot: Main chat showing a multi-step tool workflow in light and dark mode. -->

## What ModelCraft does

- **Local model conversations:** Browse, download, and switch between supported models without configuring a separate inference server.
- **Multimodal input:** Work with text, voice input, images, documents, and audio in the same conversation.
- **Projects and document context:** Keep related chats and files together, then let the assistant search project documents when answering.
- **Agent workflows:** Allow the assistant to work with files, run commands, fetch web pages, and interact with the screen through available tools.
- **Local media creation:** Generate images, audio, music, and video with supported models and keep the results in the conversation.
- **Context control:** Inspect context usage and compact long conversations when needed.

<!-- Screenshot: Projects and document context. -->

<!-- Screenshot: Model Store and model download management. -->

## Getting started

### Requirements

- macOS 15 or later

### Install a release

Download the latest available build from [GitHub Releases](https://github.com/zhang-hongshen/ModelCraft/releases). Open ModelCraft, download a compatible model from the Model Store, and start a conversation.

### Build from source

1. Clone this repository.
2. Open `ModelCraft.xcodeproj` in Xcode.
3. Select the ModelCraft scheme and a macOS destination.
4. Build and run the app. Xcode resolves the Swift package dependencies declared by the project.

## How it works

ModelCraft runs supported models directly on your device. A conversation can remain a simple local chat or become an agent workflow: attach context, enable the tools you want to expose, and let the model choose the appropriate tool from its description as the task develops.

Projects provide a persistent workspace for related chats and documents. System capabilities are available for tasks that involve files, commands, or screen interaction.

## Privacy and network access

Local inference and conversation data stay on your device. Model downloads, web access, and other explicitly connected features require a network connection and may send requests to the service you choose to use.

## Documentation and contributing

- Read the [project documentation](https://deepwiki.com/zhang-hongshen/ModelCraft).
- Report bugs or propose features through [GitHub Issues](https://github.com/zhang-hongshen/ModelCraft/issues).
- Contributions are welcome. Please open an issue before starting a large change so its scope can be discussed first.

## License

ModelCraft is open source under the [MIT License](./LICENSE).
