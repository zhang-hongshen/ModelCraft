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
    @State private var threadToRename: Thread?
    @State private var threadTitle = ""
    @State private var isRenamePresented = false

    @Query(Project.fetch()) private var projects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore

    var body: some View {
        @Bindable var store = globalStore
        List(selection: $store.currentTab) {
            Button {
                globalStore.startNewThread()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .modifier(FileDropTarget { globalStore.startNewThread(attaching: $0) })

            Label("Model Store", systemImage: "storefront")
                .tag(AppNavigationTab.modelStore)
            Label("Downloaded", systemImage: "shippingbox")
                .tag(AppNavigationTab.downloadedModels)
            Label("Connectors", systemImage: "app.connected.to.app.below.fill")
                .tag(AppNavigationTab.connectors)
            Label("Scheduled", systemImage: "clock.arrow.circlepath")
                .tag(AppNavigationTab.schedules)

            ProjectSidebarSection(
                projects: projects,
                isExpanded: $isProjectsExpanded,
                onCreateProject: createProject,
                onCreateThread: globalStore.startNewThread,
                onEditProject: editProject,
                onDeleteProject: deleteProject,
                onDeleteThread: deleteThread,
                onRenameThread: beginRenaming,
                onMoveThread: moveThread)

            RecentThreadsSection(
                projects: projects,
                isExpanded: $isRecentsExpanded,
                onDeleteThread: deleteThread,
                onRenameThread: beginRenaming,
                onMoveThread: moveThread)
        }
        .listStyle(.sidebar)
        .sheet(item: $selectedProject) { project in
            ProjectEdition(project: project)
                .presentationDetents([.medium, .large])
        }
        .alert("Rename Chat", isPresented: $isRenamePresented) {
            TextField("Chat Title", text: $threadTitle)
            Button("Cancel", role: .cancel) {
                threadToRename = nil
            }
            Button("Rename") {
                renameThread()
            }
            .disabled(threadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .focusedSceneValue(\.sidebarCommands, sidebarCommands)
    }

    /// The File and Thread menus' actions, the same as the sidebar's buttons and context menus.
    private var sidebarCommands: SidebarMenuCommands {
        guard case .thread(let thread) = globalStore.currentTab else {
            return SidebarMenuCommands(newProject: createProject)
        }
        return SidebarMenuCommands(
            newProject: createProject,
            renameThread: { beginRenaming(thread) },
            deleteThread: { deleteThread(thread) })
    }

    private func createProject() {
        selectedProject = Project()
    }

    private func editProject(_ project: Project) {
        selectedProject = project
    }

    private func deleteProject(_ project: Project) {
        if case .thread(let thread) = globalStore.currentTab,
           thread.project == project {
            globalStore.startNewThread()
        }
        project.deleteIndex()
        project.threads.forEach { $0.deleteDirectory() }
        modelContext.delete(project)
        try? modelContext.save()
    }

    private func deleteThread(_ thread: Thread) {
        if globalStore.currentTab == .thread(thread) {
            globalStore.startNewThread()
        }
        thread.deleteDirectory()
        modelContext.delete(thread)
        try? modelContext.save()
    }

    private func beginRenaming(_ thread: Thread) {
        threadToRename = thread
        threadTitle = thread.title ?? ""
        isRenamePresented = true
    }

    private func renameThread() {
        guard let threadToRename else { return }
        threadToRename.title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        self.threadToRename = nil
    }

    private func moveThread(_ thread: Thread, to project: Project?) {
        thread.project = project
        try? modelContext.save()
    }
}

private struct ProjectSidebarSection: View {

    let projects: [Project]
    @Binding var isExpanded: Bool
    let onCreateProject: () -> Void
    let onCreateThread: (Project?) -> Void
    let onEditProject: (Project) -> Void
    let onDeleteProject: (Project) -> Void
    let onDeleteThread: (Thread) -> Void
    let onRenameThread: (Thread) -> Void
    let onMoveThread: (Thread, Project?) -> Void

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(projects) { project in
                ProjectSidebarRow(
                    project: project,
                    projects: projects,
                    onCreateThread: { onCreateThread(project) },
                    onEdit: { onEditProject(project) },
                    onDelete: { onDeleteProject(project) },
                    onDeleteThread: onDeleteThread,
                    onRenameThread: onRenameThread,
                    onMoveThread: onMoveThread)
            }
        } header: {
            HStack {
                Text("Projects")

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
    let projects: [Project]
    let onCreateThread: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDeleteThread: (Thread) -> Void
    let onRenameThread: (Thread) -> Void
    let onMoveThread: (Thread, Project?) -> Void

    @State private var isExpanded = true
    @Query private var threads: [Thread]
    @Environment(GlobalStore.self) private var globalStore

    init(
        project: Project,
        projects: [Project],
        onCreateThread: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDeleteThread: @escaping (Thread) -> Void,
        onRenameThread: @escaping (Thread) -> Void,
        onMoveThread: @escaping (Thread, Project?) -> Void
    ) {
        self.project = project
        self.projects = projects
        self.onCreateThread = onCreateThread
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onDeleteThread = onDeleteThread
        self.onRenameThread = onRenameThread
        self.onMoveThread = onMoveThread

        let projectID = project.id
        _threads = Query(
            filter: #Predicate<Thread> { thread in
                thread.project?.id == projectID
            },
            sort: \.createdAt,
            order: .reverse)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(threads) { thread in
                Text(thread.title ?? String(localized: "New Chat"))
                    .lineLimit(1)
                    .tag(AppNavigationTab.thread(thread))
                    .contextMenu {
                        Button("Rename") {
                            onRenameThread(thread)
                        }

                        ThreadProjectMenu(projects: projects, currentProject: project) {
                            onMoveThread(thread, $0)
                        }

                        DeleteButton(style: .textOnly) {
                            onDeleteThread(thread)
                        }
                    }
            }
        } label: {
            HStack(spacing: 8) {
                Label(project.title, systemImage: "folder")
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: onCreateThread) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New Chat")
            }
            .modifier(FileDropTarget { globalStore.startNewThread(in: project, attaching: $0) })
            .contextMenu {
                Button("Edit", action: onEdit)
                DeleteButton(style: .textOnly, action: onDelete)
            }
        }
    }
}

private struct RecentThreadsSection: View {

    let projects: [Project]
    @Binding var isExpanded: Bool
    let onDeleteThread: (Thread) -> Void
    let onRenameThread: (Thread) -> Void
    let onMoveThread: (Thread, Project?) -> Void

    @Query(Thread.fetchRecents()) private var threads: [Thread]

    var body: some View {
        Section("Recents", isExpanded: $isExpanded) {
            ForEach(threads) { thread in
                Text(thread.title ?? String(localized: "New Chat"))
                    .lineLimit(1)
                    .tag(AppNavigationTab.thread(thread))
                    .contextMenu {
                        Button("Rename") {
                            onRenameThread(thread)
                        }

                        ThreadProjectMenu(projects: projects, currentProject: nil) {
                            onMoveThread(thread, $0)
                        }

                        DeleteButton(style: .textOnly) {
                            onDeleteThread(thread)
                        }
                    }
            }
        }
    }
}

private struct ThreadProjectMenu: View {

    let projects: [Project]
    let currentProject: Project?
    let onMove: (Project?) -> Void

    private var availableProjects: [Project] {
        guard let currentProject else { return projects }
        return projects.filter { $0.id != currentProject.id }
    }

    var body: some View {
        if currentProject != nil || !availableProjects.isEmpty {
            Menu("Move to project") {
                if let currentProject {
                    Button {
                        onMove(nil)
                    } label: {
                        Text("Remove from \(currentProject.title)")
                    }

                    if !availableProjects.isEmpty {
                        Divider()
                    }
                }

                ForEach(availableProjects) { project in
                    Button {
                        onMove(project)
                    } label: {
                        Text(project.title)
                    }
                }
            }
        }
    }
}

/// Sidebar actions for the menu bar. A `nil` thread action is disabled in the menu.
struct SidebarMenuCommands {
    var newProject: () -> Void
    var renameThread: (() -> Void)?
    var deleteThread: (() -> Void)?
}

extension FocusedValues {
    @Entry var sidebarCommands: SidebarMenuCommands?
}

#if DEBUG
#Preview(traits: .preview) {
    AppNavigationView()
}
#endif

/// Starts a new thread with the files dropped on a sidebar row, highlighting the row while
/// files are over it.
private struct FileDropTarget: ViewModifier {

    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                if isTargeted {
                    RoundedRectangle()
                        .fill(.primary.opacity(0.15))
                        .padding(-4)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: {
                isTargeted = $0
            }
    }
}
