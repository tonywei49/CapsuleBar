import Darwin
import Foundation

struct SystemStats {
    var cpuPercent: Double = 0          // 0...100 across all cores
    var memoryUsed: UInt64 = 0          // app memory + wired + compressed
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory

    var memoryPercent: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100
    }
}

/// Whole-machine CPU and memory, same definitions as Activity Monitor.
final class SystemSampler: @unchecked Sendable {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var lastCPU: Double = 0

    func sample() -> SystemStats {
        var stats = SystemStats()
        stats.cpuPercent = cpu()
        stats.memoryUsed = memoryUsed()
        return stats
    }

    private func cpu() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return lastCPU }
        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let prev = previousTicks, total > prev.total else { return lastCPU }
        lastCPU = Double(busy - prev.busy) / Double(total - prev.total) * 100
        return lastCPU
    }

    private func memoryUsed() -> UInt64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
        return (appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
    }
}
