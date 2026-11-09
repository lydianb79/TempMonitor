import Foundation

enum SensorGroup: String {
    case cpu = "CPU"
    case gpu = "GPU"
    case other = "SoC / Other"
}

struct SensorReading: Identifiable, Hashable {
    let id: String
    let name: String
    let group: SensorGroup
    let value: Double   // °C
}

/// Discovers and reads CPU / GPU temperature sensors.
/// Works on Intel (SMC sp78 keys) and Apple Silicon (SMC flt keys + IOHID fallback).
/// The architecture is detected at runtime, so an x86_64 build running under Rosetta
/// still picks the Apple Silicon sensor set.
final class SensorHub {
    let isAppleSilicon: Bool
    private let smcAvailable: Bool
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []

    init() {
        isAppleSilicon = SensorHub.detectAppleSilicon()
        smcAvailable = tm_smc_open() != 0
        if smcAvailable { discoverSMCKeys() }
    }

    deinit { tm_smc_close() }

    // MARK: Discovery

    static func detectAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private func allSMCKeys() -> [String] {
        let count = Int(tm_smc_key_count())
        guard count > 0 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(count)
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<count where tm_smc_key_at(Int32(i), &buf) != 0 {
            keys.append(String(cString: buf))
        }
        return keys
    }

    private static func plausible(_ v: Double) -> Bool { v > 5 && v < 130 }

    private func readKey(_ key: String) -> Double? {
        var v = 0.0
        guard tm_smc_read(key, &v) != 0, SensorHub.plausible(v) else { return nil }
        return v
    }

    private func discoverSMCKeys() {
        let temps = allSMCKeys().filter { $0.hasPrefix("T") && $0.count == 4 }
        let valid: (String) -> Bool = { self.readKey($0) != nil }

        if isAppleSilicon {
            // M1/M2/M4: Tp* (performance cores), Te* (efficiency cores), Tg* (GPU)
            cpuKeys = temps.filter { ($0.hasPrefix("Tp") || $0.hasPrefix("Te")) && valid($0) }
            gpuKeys = temps.filter { $0.hasPrefix("Tg") && valid($0) }
            // M3 family exposes cluster temps under Tf*
            if cpuKeys.isEmpty { cpuKeys = temps.filter { ($0.hasPrefix("Tf0") || $0.hasPrefix("Tf4")) && valid($0) } }
            if gpuKeys.isEmpty { gpuKeys = temps.filter { ($0.hasPrefix("Tf1") || $0.hasPrefix("Tf2")) && valid($0) } }
        } else {
            let pool = temps.isEmpty
                ? ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCXC"] + (1...16).map { "TC\(String($0, radix: 16).uppercased())C" }
                  + ["TG0P", "TG0D", "TG0H", "TGDD", "TG1D", "TCGC"]
                : temps
            let cores = pool.filter { k in
                k.hasPrefix("TC") && k.hasSuffix("C") && k != "TCGC" && k != "TCSC" && valid(k)
            }
            if cores.isEmpty {
                cpuKeys = Array(["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"].filter(valid).prefix(1))
            } else {
                cpuKeys = cores
            }
            gpuKeys = ["TG0D", "TG0P", "TG0H", "TGDD", "TG1D"].filter { pool.contains($0) && valid($0) }
            if gpuKeys.isEmpty, valid("TCGC") { gpuKeys = ["TCGC"] }   // integrated Intel GPU
        }
    }

    // MARK: Reading

    func read() -> [SensorReading] {
        var out: [SensorReading] = []
        if smcAvailable {
            for k in cpuKeys { if let v = readKey(k) { out.append(.init(id: "smc.\(k)", name: label(for: k), group: .cpu, value: v)) } }
            for k in gpuKeys { if let v = readKey(k) { out.append(.init(id: "smc.\(k)", name: label(for: k), group: .gpu, value: v)) } }
        }
        if isAppleSilicon {
            let haveCPU = out.contains { $0.group == .cpu }
            let haveGPU = out.contains { $0.group == .gpu }
            var seen: [String: Int] = [:]
            for s in readHID() {
                var group = classifyHID(s.name)
                if group == .cpu && haveCPU { group = .other }
                if group == .gpu && haveGPU { group = .other }
                let n = (seen[s.name] ?? 0) + 1
                seen[s.name] = n
                let name = n > 1 ? "\(s.name) #\(n)" : s.name
                out.append(.init(id: "hid.\(name)", name: name, group: group, value: s.value))
            }
        }
        return out
    }

    private func readHID() -> [(name: String, value: Double)] {
        var buffer = [TMHIDSensor](repeating: TMHIDSensor(), count: 128)
        let n = Int(tm_hid_read(&buffer, Int32(buffer.count)))
        return buffer.prefix(n).compactMap { s -> (name: String, value: Double)? in
            var copy = s
            let name = withUnsafePointer(to: &copy.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            return SensorHub.plausible(s.value) ? (name: name, value: s.value) : nil
        }
    }

    private func classifyHID(_ name: String) -> SensorGroup {
        let n = name.lowercased()
        if n.contains("gpu") { return .gpu }
        if n.contains("tdie") || n.contains("pacc") || n.contains("eacc") || n.contains("cpu") { return .cpu }
        return .other
    }

    private func label(for key: String) -> String {
        if isAppleSilicon {
            switch key.prefix(2) {
            case "Tp": return "P-Core \(key)"
            case "Te": return "E-Core \(key)"
            case "Tg": return "GPU \(key)"
            case "Tf": return (key.hasPrefix("Tf1") || key.hasPrefix("Tf2")) ? "GPU \(key)" : "CPU \(key)"
            default:   return key
            }
        }
        switch key {
        case "TC0P": return "CPU Proximity"
        case "TC0D", "TC0E", "TC0F": return "CPU Die"
        case "TC0H": return "CPU Heatsink"
        case "TCXC": return "CPU PECI"
        case "TCGC": return "Integrated GPU"
        case "TG0P": return "GPU Proximity"
        case "TG0D", "TGDD", "TG1D": return "GPU Die"
        case "TG0H": return "GPU Heatsink"
        default:
            if key.hasPrefix("TC"), key.hasSuffix("C"), let n = Int(String(key.dropFirst(2).prefix(1)), radix: 16) {
                return "Core \(n)"
            }
            return key
        }
    }
}
