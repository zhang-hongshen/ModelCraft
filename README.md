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

ModelCraft brings local language and media models into one native macOS app. Chat with a model, organize work into projects, provide files as context, connect your Mac apps, schedule recurring tasks, and let the assistant use tools to complete multi-step tasks.

<picture>
  <source media="(prefers-color-scheme: light)" srcset="Screenshots/chat.png" />
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/chat-dark.png" />
  <img alt="ModelCraft chat with a multi-step tool workflow" src="Screenshots/chat.png" />
</picture>

## What ModelCraft does

- **Local model conversations:** Browse, download, and switch between supported models without configuring a separate inference server. Follow-up turns reuse the prompt cache, and large mixture-of-experts models such as DeepSeek V4 Flash stream experts from disk when they do not fit in memory.
- **Multimodal input:** Work with text, voice input, images, documents, and audio in the same conversation.
- **Projects and document context:** Keep related chats and files together, then let the assistant search project documents when answering.
- **Agent workflows:** Allow the assistant to work with files, run commands, fetch web pages, use Notes, Calendar, Reminders, and Mail, and interact with the screen. Less common tools load on demand, so every request stays small.
- **Connectors:** Install companion Mac apps (Arthub, Cellar, Keel, TuneStudio) and the assistant can read and act on their data through MCP tools, with approval for anything that changes it.
- **Scheduled tasks:** Run a prompt once or on an hourly, daily, weekly, monthly, or yearly schedule. Rules can follow workdays and public holidays, and each run lands in a new chat with an optional notification.
- **Local media creation:** Generate images, audio, music, and video with supported models and keep the results in the conversation.
- **Context control:** Inspect context usage and compact long conversations when needed.

<table>
  <tr>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/model-store.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/model-store-dark.png" />
        <img alt="Model Store" src="Screenshots/model-store.png" />
      </picture>
      <br /><sub>Model Store</sub>
    </td>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/connectors.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connectors-dark.png" />
        <img alt="Connectors" src="Screenshots/connectors.png" />
      </picture>
      <br /><sub>Connectors</sub>
    </td>
    <td align="center" width="33%">
      <picture>
        <source media="(prefers-color-scheme: light)" srcset="Screenshots/scheduled-tasks.png" />
        <source media="(prefers-color-scheme: dark)" srcset="Screenshots/scheduled-tasks-dark.png" />
        <img alt="Scheduled Tasks" src="Screenshots/scheduled-tasks.png" />
      </picture>
      <br /><sub>Scheduled Tasks</sub>
    </td>
  </tr>
</table>

## Getting started

### Requirements

- macOS 15 or later

### Install a release

Download the latest available build from [GitHub Releases](https://github.com/zhang-hongshen/ModelCraft/releases). Open the `ModelCraft_<version>.dmg`, drag ModelCraft into Applications, then open it, download a compatible model from the Model Store, and start a conversation.

Release builds are ad-hoc signed and not notarized by Apple, so macOS blocks the first launch. Either open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```bash
xattr -cr /Applications/ModelCraft.app
```

## Documentation

Read the [project documentation](https://deepwiki.com/zhang-hongshen/ModelCraft).

## License

ModelCraft is open source under the [MIT License](./LICENSE).
