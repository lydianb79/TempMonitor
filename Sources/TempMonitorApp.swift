import SwiftUI
import AppKit
import Combine

@main
struct TempMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("Export History as CSV…") { TemperatureMonitor.shared.recorder.exportWithPanel() }
                    .keyboardShortcut("s")
                Button("Export Graph as PNG…") { TemperatureMonitor.shared.recorder.exportGraphWithPanel(.png) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export Graph as PDF…") { TemperatureMonitor.shared.recorder.exportGraphWithPanel(.pdf) }
                Button("Open Saved Logs Folder") { TemperatureMonitor.shared.recorder.openLogFolder() }
                Divider()
                Button("Clear History") { TemperatureMonitor.shared.recorder.clear() }
            }
        }
    }
}

/// Puts a live "🔥 CPU · GPU" readout in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "TempMonitor")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " --°"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show TempMonitor", action: #selector(showWindow), keyEquivalent: ""))
        let export = NSMenuItem(title: "Export History as CSV…", action: #selector(exportHistory), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        let graph = NSMenuItem(title: "Export Graph as PNG…", action: #selector(exportGraph), keyEquivalent: "")
        graph.target = self
        menu.addItem(graph)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action == #selector(showWindow) { $0.target = self } }
        item.menu = menu
        statusItem = item

        // Keep the window object alive when closed so the menu-bar item can bring it back.
        DispatchQueue.main.async {
            NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.isReleasedWhenClosed = false }
        }

        let monitor = TemperatureMonitor.shared
        monitor.$cpu.combineLatest(monitor.$gpu)
            .receive(on: RunLoop.main)
            .sink { [weak self] cpu, gpu in
                let unit = TempUnit(rawValue: UserDefaults.standard.string(forKey: "unit") ?? "") ?? .celsius
                var parts: [String] = []
                if cpu.current != nil { parts.append("CPU \(unit.format(cpu.current))") }
                if gpu.current != nil { parts.append("GPU \(unit.format(gpu.current))") }
                self?.statusItem?.button?.title = " " + (parts.isEmpty ? "--°" : parts.joined(separator: "  "))
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TemperatureMonitor.shared.recorder.autoSaveIfEnabled()
    }

    @objc private func exportGraph() {
        TemperatureMonitor.shared.recorder.exportGraphWithPanel(.png)
    }

    @objc private func exportHistory() {
        TemperatureMonitor.shared.recorder.exportWithPanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }
}
