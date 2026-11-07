import SwiftUI
import SwiftData

enum ChatInspectorTab: String {
    case tasks, files
}

struct ChatInspectorHeader: View {
    @Binding var tab: ChatInspectorTab
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Picker("Inspector", selection: $tab) {
                Text("Tasks").tag(ChatInspectorTab.tasks)
                Text("Files").tag(ChatInspectorTab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button("Close Inspector", systemImage: "xmark") { isPresented = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Close Inspector")
        }
        .padding()
    }
}

struct TaskInspectorView: View {
    let chat: Chat?
    @Query private var tickets: [Ticket]

    init(chat: Chat?, project: Project?) {
        self.chat = chat
        _tickets = Query(Ticket.fetch(chat: chat, project: project))
    }

    var body: some View {
        let inProgress = tickets.filter { $0.status != .completed }
        let completed = tickets.filter { $0.status == .completed }

        List {
            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { ticket in
                        TaskInspectorRow(ticket: ticket, isCurrent: ticket.id == chat?.activeTicket?.id)
                    }
                }
            }
            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { ticket in
                        TaskInspectorRow(ticket: ticket, isCurrent: ticket.id == chat?.activeTicket?.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if tickets.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checklist")
            }
        }
    }
}

private struct TaskInspectorRow: View {
    let ticket: Ticket
    let isCurrent: Bool

    var body: some View {
        HStack {
            Label(ticket.title, systemImage: ticket.status.symbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isCurrent {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(Text(ticket.status.title))
        .accessibilityValue(Text(ticket.status.title))
    }
}
