import SwiftUI

struct ProcessMemoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    @State private var query = ""
    @State private var selectedID: ProcessMemoryItem.ID?
    @State private var selectedProcess: ProcessMemoryItem?
    @State private var pendingTermination: TerminationRequest?
    @State private var showingConfirmation = false
    @State private var actionNotice: ActionNotice?

    private struct TerminationRequest {
        let process: ProcessMemoryItem
        let action: ProcessTerminator.Action
    }

    private struct ActionNotice {
        let message: String
        let isError: Bool
    }

    private var canActOnSelection: Bool {
        selectedProcess.map(ProcessTerminator.canTerminate) ?? false
    }

    private var visibleItems: [ProcessMemoryItem] {
        guard let items = monitor.processes?.items else { return [] }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return items }
        let pid = Int32(search)
        return items.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.pid == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory by process")
                        .font(.title3.weight(.semibold))
                    Text("\(monitor.processes?.items.count ?? 0) processes · largest footprint first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search name or PID", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search processes")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(8)
                .frame(width: 240)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = monitor.processError {
                Label("\(error) Process readings may be stale.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button("Terminate…") {
                    if let process = selectedProcess { request(.terminate, for: process) }
                }
                .disabled(!canActOnSelection)
                .help("Send SIGTERM after confirmation; the process can handle or ignore it")
                Button("Force Kill…") {
                    if let process = selectedProcess { request(.forceKill, for: process) }
                }
                .disabled(!canActOnSelection)
                .help("Send SIGKILL after confirmation; unsaved work will be lost")
                if let process = selectedProcess {
                    Text("\(process.name) · PID \(process.pid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Clear Selection", action: clearSelection)
                        .buttonStyle(.link)
                } else {
                    Text("Select a process to act on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let process = selectedProcess, (process.startTime ?? 0) == 0 {
                Text("The selected process’s start time is unavailable. Terminate and Force Kill are disabled; refresh and select a row with a readable identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = actionNotice {
                Label(notice.message, systemImage: notice.isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(notice.isError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Table(visibleItems, selection: $selectedID) {
                TableColumn("Process") { item in
                    HStack(spacing: 8) {
                        Image(systemName: "app")
                            .foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1)
                    }
                    .help(item.name)
                }
                .width(min: 260, ideal: 420)
                TableColumn("PID · % of 32 GiB") { item in
                    HStack(spacing: 10) {
                        Text(String(item.pid)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(item.footprint.map { String(format: "%.2f%%", Double($0) / Double(monitor.snapshot?.total ?? ProcessInfo.processInfo.physicalMemory) * 100) } ?? "—")
                    }
                    .monospacedDigit()
                    .help("Process footprint as a percentage of the full installed 32 GiB, not a percentage of used memory. Footprint includes compressed memory.")
                }
                .width(150)
                TableColumn("Memory footprint") { item in
                    Text(item.footprint.map(memoryAmount) ?? "Unavailable")
                        .monospacedDigit()
                        .fontWeight(item.footprint != nil ? .medium : .regular)
                        .foregroundStyle(item.footprint != nil ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(160)
            }
            .overlay {
                if monitor.processes == nil && monitor.processError == nil {
                    ProgressView("Reading running processes…")
                } else if visibleItems.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxHeight: .infinity)
            .onChange(of: selectedID) { _, identity in
                selectedProcess = visibleItems.first { $0.id == identity }
            }
            .onChange(of: query) { _, _ in
                if let selectedID, !visibleItems.contains(where: { $0.id == selectedID }) {
                    clearSelection()
                }
            }
            .onChange(of: monitor.processes?.timestamp) { _, _ in
                guard let captured = selectedProcess else { return }
                // Never silently move a selection to a replacement that reused its PID.
                guard visibleItems.contains(where: { $0.id == captured.id }) else {
                    clearSelection()
                    return
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let snapshot = monitor.processes {
                        Text("\(snapshot.unavailableCount) memory readings unavailable")
                        Spacer()
                        Text("Updated \(snapshot.timestamp.formatted(date: .omitted, time: .standard))")
                            .monospacedDigit()
                    }
                }
                Text("Each row is a process, including app helpers. Footprint is macOS’s memory charge for that process, including compressed memory; it is not just resident RAM. The rows do not add up to the physical-memory overview. Protected processes may be unavailable.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Termination requires a readable process start time. PID 1 and this app are protected. SIGTERM requests termination; SIGKILL forces it. App helpers may restart automatically.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("\(pendingTermination?.action.buttonTitle ?? "Terminate") process?",
               isPresented: $showingConfirmation, presenting: pendingTermination) { request in
            Button("\(request.action.buttonTitle) (\(request.action.signalName))", role: .destructive) {
                send(request)
            }
            Button("Cancel", role: .cancel) {
                pendingTermination = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: { request in
            Text("\(request.process.name) (PID \(request.process.pid)) will receive \(request.action.signalName). \(request.action == .forceKill ? "It will be stopped without a chance to save." : "It may exit without saving, or may handle or ignore the request.") Unsaved work may be lost. Helpers may restart automatically.")
        }
    }

    private func clearSelection() {
        selectedID = nil
        selectedProcess = nil
    }

    private func request(_ action: ProcessTerminator.Action, for process: ProcessMemoryItem) {
        guard ProcessTerminator.canTerminate(process) else { return }
        // The dialog retains this exact identity even if sampling updates the table.
        pendingTermination = TerminationRequest(process: process, action: action)
        showingConfirmation = true
    }

    private func send(_ request: TerminationRequest) {
        pendingTermination = nil
        do {
            try ProcessTerminator.send(request.action, to: request.process)
            monitor.refresh()
            actionNotice = ActionNotice(
                message: "\(request.action.signalName) sent to \(request.process.name) (PID \(request.process.pid)). Exit is not yet confirmed; refresh requested. Helpers may restart.",
                isError: false
            )
        } catch {
            actionNotice = ActionNotice(
                message: "\(request.process.name) (PID \(request.process.pid)): \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
