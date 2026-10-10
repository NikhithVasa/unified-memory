import SwiftUI

@main
struct UnifiedMemoryApp: App {
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        Window("Unified Memory", id: "memory") {
            ContentView(monitor: monitor)
        }
        .defaultSize(width: 940, height: 880)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Monitor") {
                Button(monitor.isPaused ? "Resume Live Updates" : "Pause Live Updates") {
                    monitor.togglePause()
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Refresh Now") { monitor.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                ForEach([1, 2, 5], id: \.self) { seconds in
                    Button("Update Every \(seconds) Second\(seconds == 1 ? "" : "s")\(monitor.interval == seconds ? " ✓" : "")") {
                        monitor.setInterval(seconds)
                    }
                }
            }
        }
    }
}
