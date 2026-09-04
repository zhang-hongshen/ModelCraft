//
//  AppNavigationView.swift
//  ModelCraft
//
//  Created by Hongshen on 16/5/26.
//

import SwiftUI
import SwiftData

struct AppNavigationView: View {

    @State private var selectedProject: Project? = nil
    @State private var isProjectsExpanded = true
    @State private var isRecentsExpanded = true

    @Query(Chat.fetchRecents()) private var chats: [Chat]
    @Query(Project.fetch()) private var projects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore

    var body: some View {
        @Bindable var store = globalStore
        List(selection: $store.currentTab) {
            Button {
                globalStore.startNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)

            Label("Model Store", systemImage: "storefront")
                .tag(AppNavigationTab.modelStore)
            Label("Downloaded Models", systemImage: "shippingbox")
                .tag(AppNavigationTab.downloadedModels)

            ProjectSidebarSection(
                projects: projects,
                isExpanded: $isProjectsExpanded,
                onCreateProject: createProject,
                onCreateChat: globalStore.startNewChat,
                onEditProject: editProject,
                onDeleteProject: deleteProject,
                onDeleteChat: deleteChat)

            RecentChatsSection(
                chats: chats,
                projects: projects,
                isExpanded: $isRecentsExpanded,
                onDeleteChat: deleteChat,
                onMoveChat: moveChat)
        }
        .listStyle(.sidebar)
        .sheet(item: $selectedProject) { project in
            ProjectEdition(project: project)
                .presentationDetents([.medium, .large])
        }
    }

    private func createProject() {
        selectedProject = Project()
    }

    private func editProject(_ project: Project) {
        selectedProject = project
    }

    private func deleteProject(_ project: Project) {
        if case .chat(let chat) = globalStore.currentTab,
           chat.project == project {
            globalStore.startNewChat()
        }
        project.deleteStoredResources()
        modelContext.delete(project)
        try? modelContext.save()
    }

    private func deleteChat(_ chat: Chat) {
        if globalStore.currentTab == .chat(chat) {
            globalStore.startNewChat()
        }
        modelContext.delete(chat)
        try? modelContext.save()
    }

    private func moveChat(_ chat: Chat, to project: Project) {
        chat.project = project
        try? modelContext.save()
    }
}

private struct ProjectSidebarSection: View {

    let projects: [Project]
    @Binding var isExpanded: Bool
    let onCreateProject: () -> Void
    let onCreateChat: (Project?) -> Void
    let onEditProject: (Project) -> Void
    let onDeleteProject: (Project) -> Void
    let onDeleteChat: (Chat) -> Void

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(projects) { project in
                ProjectSidebarRow(
                    project: project,
                    onCreateChat: { onCreateChat(project) },
                    onEdit: { onEditProject(project) },
                    onDelete: { onDeleteProject(project) },
                    onDeleteChat: onDeleteChat)
            }
        } header: {
            HStack {
                Text("Projects")

                Spacer()

                Button(action: onCreateProject) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Project")
                .accessibilityLabel("New Project")
            }
        }
    }
}

private struct ProjectSidebarRow: View {

    let project: Project
    let onCreateChat: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDeleteChat: (Chat) -> Void

    @State private var isExpanded = true
    @Query private var chats: [Chat]

    init(
        project: Project,
        onCreateChat: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDeleteChat: @escaping (Chat) -> Void
    ) {
        self.project = project
        self.onCreateChat = onCreateChat
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onDeleteChat = onDeleteChat

        let projectID = project.id
        _chats = Query(
            filter: #Predicate<Chat> { chat in
                chat.project?.id == projectID
            },
            sort: \.createdAt,
            order: .reverse)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(chats) { chat in
                Text(chat.title ?? String(localized: "New Chat"))
                    .lineLimit(1)
                    .tag(AppNavigationTab.chat(chat))
                    .contextMenu {
                        DeleteButton(style: .textOnly) {
                            onDeleteChat(chat)
                        }
                    }
            }
        } label: {
            HStack(spacing: 8) {
                Label(project.title, systemImage: "folder")
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: onCreateChat) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New Chat")
            }
            .contextMenu {
                Button("Edit", action: onEdit)
                DeleteButton(style: .textOnly, action: onDelete)
            }
        }
    }
}

private struct RecentChatsSection: View {

    let chats: [Chat]
    let projects: [Project]
    @Binding var isExpanded: Bool
    let onDeleteChat: (Chat) -> Void
    let onMoveChat: (Chat, Project) -> Void

    var body: some View {
        Section("Recents", isExpanded: $isExpanded) {
            ForEach(chats) { chat in
                Text(chat.title ?? String(localized: "New Chat"))
                    .lineLimit(1)
                    .tag(AppNavigationTab.chat(chat))
                    .contextMenu {
                        DeleteButton(style: .textOnly) {
                            onDeleteChat(chat)
                        }

                        if !projects.isEmpty {
                            Menu("Move to project") {
                                ForEach(projects) { project in
                                    Button(project.title) {
                                        onMoveChat(chat, project)
                                    }
                                }
                            }
                        }
                    }
            }
        }
    }
}

#Preview(traits: .preview) {
    AppNavigationView()
}
