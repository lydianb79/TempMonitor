import Foundation
import Combine
import Metal

struct GroupStats {
    var current: Double? = nil      // average of the group's sensors
    var hottest: Double? = nil      // hottest single sensor right now
    var sessionMax: Double? = nil
    var sessionMin: Double? = nil
    var history: [Double] = []      // averages, oldest first

    mutating func push(_ values: [Double], limit: Int) {
        guard !values.isEmpty else { current = nil; hottest = nil; return }
        let avg = values.reduce(0, +) / Double(values.count)
        current = avg
        hottest = values.max()
        sessionMax = max(sessionMax ?? avg, avg)
        sessionMin = min(sessionMin ?? avg, avg)
        history.append(avg)
        if history.count > limit { history.removeFirst(history.count - limit) }
    }
}

final class TemperatureMonitor: ObservableObject {
    static let shared = TemperatureMonitor()

    @Published private(set) var cpu = GroupStats()
    @Published private(set) var gpu = GroupStats()
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var ready = false
    @Published var interval: Double = 1.0 { didSet { schedule() } }

    let recorder = HistoryRecorder()
    let chipName: String
    let gpuName: String
    let historyLength = 120

    private var hub: SensorHub?
    private let queue = DispatchQueue(label: "TempMonitor.sensors", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {
        chipName = TemperatureMonitor.sysctlString("machdep.cpu.brand_string") ?? "Mac"
        gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
        queue.async { [weak self] in
            self?.hub = SensorHub()
            DispatchQueue.main.async { self?.schedule() }
        }
    }

    var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return SensorHub.detectAppleSilicon() ? "x86_64 (Rosetta)" : "x86_64"
        #endif
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: max(0.25, interval), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let hub = hub else { return }
        let readings = hub.read()
        let cpuValues = readings.filter { $0.group == .cpu }.map(\.value)
        let gpuValues = readings.filter { $0.group == .gpu }.map(\.value)
        DispatchQueue.main.async {
            self.cpu.push(cpuValues, limit: self.historyLength)
            self.gpu.push(gpuValues, limit: self.historyLength)
            self.recorder.append(readings, cpu: self.cpu.current, gpu: self.gpu.current)
            self.sensors = readings.sorted { ($0.group.rawValue, $0.name) < ($1.group.rawValue, $1.name) }
            self.ready = true
        }
    }

    func resetSession() {
        cpu = GroupStats()
        gpu = GroupStats()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
