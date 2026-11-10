import Foundation
import Darwin

struct UsageSnapshot {
    var cpu: Double?                 // overall CPU load, 0–100
    var perCore: [Double] = []       // per logical core, 0–100
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0          // app + wired + compressed (like Activity Monitor)
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0

    var memPercent: Double? {
        memTotal > 0 && memUsed > 0 ? Double(memUsed) / Double(memTotal) * 100 : nil
    }
}

/// Samples CPU load (from tick deltas between calls) and memory usage via Mach APIs.
final class SystemUsageSampler {
    private var previous: [[UInt32]] = []   // per core: user, system, idle, nice ticks
    private let pageSize = UInt64(vm_kernel_page_size)

    func sample() -> UsageSnapshot {
        var s = UsageSnapshot()
        (s.cpu, s.perCore) = cpuLoad()
        readMemory(into: &s)
        return s
    }

    private func cpuLoad() -> (Double?, [Double]) {
        var numCPUs: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCPUs, &infoArray, &infoCount) == KERN_SUCCESS,
              let info = infoArray else { return (nil, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for i in 0..<Int(numCPUs) {
            let b = i * stride
            current.append([UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])])
        }
        let before = previous
        previous = current
        guard before.count == current.count, !current.isEmpty else { return (nil, []) }

        var perCore: [Double] = []
        var busyAll = 0.0, totalAll = 0.0
        for (now, old) in zip(current, before) {
            let user = Double(now[0] &- old[0]), sys = Double(now[1] &- old[1])
            let idle = Double(now[2] &- old[2]), nice = Double(now[3] &- old[3])
            let busy = user + sys + nice
            let total = busy + idle
            perCore.append(total > 0 ? busy / total * 100 : 0)
            busyAll += busy
            totalAll += total
        }
        return (totalAll > 0 ? busyAll / totalAll * 100 : nil, perCore)
    }

    private func readMemory(into s: inout UsageSnapshot) {
        s.memTotal = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let internal = UInt64(stats.internal_page_count)
            let purgeable = min(internal, UInt64(stats.purgeable_count))
            s.memApp = (internal - purgeable) * pageSize
            s.memWired = UInt64(stats.wire_count) * pageSize
            s.memCompressed = UInt64(stats.compressor_page_count) * pageSize
            s.memUsed = min(s.memTotal, s.memApp + s.memWired + s.memCompressed)
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }
    }
}
