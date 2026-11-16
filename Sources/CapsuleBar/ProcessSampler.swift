import Darwin
import Foundation

/// Per-app resource numbers for one sampling tick.
struct AppUsage {
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var processCount: Int = 0
}

/// Describes one running app the sampler should attribute processes to.
struct AppDescriptor {
    let pid: pid_t
    let bundlePath: String?
}

/// Low-level per-process sampling via libproc. Not thread-safe: use from one serial queue.
final class ProcessSampler: @unchecked Sendable {
    private let ticksToNanos: Double
    private var previousCPU: [pid_t: UInt64] = [:]   // cumulative CPU time in ns
    private var previousTime: UInt64 = 0             // uptime ns
    private var lastPercent: [pid_t: Double] = [:]
    private var pathCache: [pid_t: String] = [:]

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // proc_pid_rusage reports CPU time in mach ticks (on Apple Silicon 1 tick != 1 ns).
        ticksToNanos = Double(tb.numer) / Double(tb.denom)
    }

    /// Samples every process and rolls the numbers up into the given apps.
    func sample(apps: [AppDescriptor]) -> [pid_t: AppUsage] {
        let pids = Self.allPIDs()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTime == 0 ? 0 : now - previousTime
        // Ticks triggered by launch/quit notifications can arrive right after a timer
        // tick; a tiny window gives noisy percentages, so reuse the previous ones.
        let updateCPU = elapsed >= 800_000_000 || previousTime == 0

        var cpuNow: [pid_t: UInt64] = [:]
        var percent: [pid_t: Double] = [:]
        var footprint: [pid_t: UInt64] = [:]
        var parent: [pid_t: pid_t] = [:]
        var alive = Set<pid_t>()

        for pid in pids {
            guard let usage = Self.rusage(pid) else { continue }
            alive.insert(pid)
            let cpuNs = UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * ticksToNanos)
            cpuNow[pid] = cpuNs
            footprint[pid] = usage.ri_phys_footprint
            if updateCPU {
                if elapsed > 0, let prev = previousCPU[pid], cpuNs >= prev {
                    percent[pid] = Double(cpuNs - prev) / Double(elapsed) * 100
                } else {
                    percent[pid] = 0
                }
            } else {
                percent[pid] = lastPercent[pid] ?? 0
            }
            if let ppid = Self.parentPID(pid) { parent[pid] = ppid }
        }

        if updateCPU {
            previousCPU = cpuNow
            previousTime = now
            lastPercent = percent
        }
        pathCache = pathCache.filter { alive.contains($0.key) }

        return attribute(pids: alive, apps: apps, parent: parent, percent: percent, footprint: footprint)
    }

    /// Gives every process exactly one owning app: the nearest app ancestor, otherwise the
    /// app whose bundle contains the executable (catches XPC services / helpers launched by launchd).
    private func attribute(pids: Set<pid_t>, apps: [AppDescriptor], parent: [pid_t: pid_t],
                           percent: [pid_t: Double], footprint: [pid_t: UInt64]) -> [pid_t: AppUsage] {
        let appPIDs = Set(apps.map(\.pid))
        let bundles: [(prefix: String, pid: pid_t)] = apps
            .compactMap { app in app.bundlePath.map { ($0.hasSuffix("/") ? $0 : $0 + "/", app.pid) } }
            .sorted { $0.prefix.count > $1.prefix.count }   // longest (most specific) first

        var result: [pid_t: AppUsage] = [:]
        for pid in pids {
            var owner: pid_t?
            var cursor: pid_t? = pid
            var depth = 0
            while let p = cursor, p > 1, depth < 64 {
                if appPIDs.contains(p) { owner = p; break }
                cursor = parent[p]
                depth += 1
            }
            if owner == nil, let path = path(for: pid) {
                owner = bundles.first(where: { path.hasPrefix($0.prefix) })?.pid
            }
            guard let owner else { continue }
            var usage = result[owner] ?? AppUsage()
            usage.cpuPercent += percent[pid] ?? 0
            usage.memoryBytes += footprint[pid] ?? 0
            usage.processCount += 1
            result[owner] = usage
        }
        return result
    }

    private func path(for pid: pid_t) -> String? {
        if let cached = pathCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        pathCache[pid] = path
        return path
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_listallpids(ptr.baseAddress, Int32(ptr.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return status == 0 ? info : nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return read == size ? pid_t(info.pbi_ppid) : nil
    }
}
