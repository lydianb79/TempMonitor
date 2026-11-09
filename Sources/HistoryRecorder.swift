import Foundation
import AppKit
import UniformTypeIdentifiers

/// Records every sensor reading while the app is open and exports it as CSV.
final class HistoryRecorder: ObservableObject {
    struct Row {
        let time: Date
        let cpu: Double?
        let gpu: Double?
        let values: [Int: Double]   // column index -> °C
    }

    @Published var isRecording: Bool {
        didSet { UserDefaults.standard.set(isRecording, forKey: "recordHistory") }
    }
    @Published var autoSaveOnQuit: Bool {
        didSet { UserDefaults.standard.set(autoSaveOnQuit, forKey: "autoSaveOnQuit") }
    }
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastSavedURL: URL?

    private(set) var rows: [Row] = []
    private var columns: [String] = []          // column titles
    private var columnIndex: [String: Int] = [:] // sensor id -> column
    private let maxRows = 500_000                // ~5.8 days at 1 s

    init() {
        let d = UserDefaults.standard
        isRecording = d.object(forKey: "recordHistory") as? Bool ?? true
        autoSaveOnQuit = d.object(forKey: "autoSaveOnQuit") as? Bool ?? false
    }

    // MARK: Recording

    func append(_ readings: [SensorReading], cpu: Double?, gpu: Double?) {
        guard isRecording else { return }
        var values: [Int: Double] = [:]
        for r in readings {
            let idx: Int
            if let i = columnIndex[r.id] {
                idx = i
            } else {
                idx = columns.count
                columns.append("\(r.name) [\(r.group.rawValue)] °C")
                columnIndex[r.id] = idx
            }
            values[idx] = r.value
        }
        rows.append(Row(time: Date(), cpu: cpu, gpu: gpu, values: values))
        if rows.count > maxRows { rows.removeFirst(rows.count - maxRows) }
        sampleCount = rows.count
    }

    func clear() {
        rows.removeAll()
        sampleCount = 0
    }

    var duration: TimeInterval {
        guard let first = rows.first, let last = rows.last else { return 0 }
        return last.time.timeIntervalSince(first.time)
    }

    // MARK: Export

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func num(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }

        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        lines.append((["timestamp", "elapsed_s", "cpu_avg_C", "gpu_avg_C"] + columns.map(quote)).joined(separator: ","))
        let t0 = rows.first?.time ?? Date()
        for r in rows {
            var fields = [iso.string(from: r.time),
                          String(format: "%.1f", r.time.timeIntervalSince(t0)),
                          num(r.cpu), num(r.gpu)]
            for i in 0..<columns.count { fields.append(num(r.values[i])) }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static var logFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TempMonitor", isDirectory: true)
    }

    var fileBaseName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "TempMonitor_\(f.string(from: rows.first?.time ?? Date()))"
    }

    private var defaultFileName: String { fileBaseName + ".csv" }

    @discardableResult
    func write(to url: URL) -> Bool {
        do {
            // BOM so Excel opens the UTF-8 file (°C) correctly
            try ("\u{FEFF}" + csv()).write(to: url, atomically: true, encoding: .utf8)
            lastSavedURL = url
            return true
        } catch {
            NSLog("TempMonitor: could not save history: \(error)")
            return false
        }
    }

    func exportWithPanel() {
        guard !rows.isEmpty else { NSSound.beep(); return }
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Export Temperature History"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = defaultFileName
        panel.directoryURL = Self.logFolder
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, write(to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Called when the app quits.
    func autoSaveIfEnabled() {
        guard autoSaveOnQuit, !rows.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        write(to: Self.logFolder.appendingPathComponent(defaultFileName))
        autoSaveGraph()
    }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.logFolder)
    }
}
