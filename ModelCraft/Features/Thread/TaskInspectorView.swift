import SwiftUI
import SwiftData

enum ThreadInspectorTab: String {
    case tasks, files
}

struct ThreadInspectorHeader: View {
    @Binding var tab: ThreadInspectorTab
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Picker("Inspector", selection: $tab) {
                Text("Tasks").tag(ThreadInspectorTab.tasks)
                Text("Files").tag(ThreadInspectorTab.files)
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
    let thread: Thread?
    @Query private var tickets: [Ticket]

    init(thread: Thread?, project: Project?) {
        self.thread = thread
        _tickets = Query(Ticket.fetch(thread: thread, project: project))
    }

    var body: some View {
        let inProgress = tickets.filter { $0.status != .completed }
        let completed = tickets.filter { $0.status == .completed }

        List {
            if !inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(inProgress) { ticket in
                        TaskInspectorRow(ticket: ticket, isCurrent: ticket.id == thread?.activeTicket?.id)
                    }
                }
            }
            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { ticket in
                        TaskInspectorRow(ticket: ticket, isCurrent: ticket.id == thread?.activeTicket?.id)
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
