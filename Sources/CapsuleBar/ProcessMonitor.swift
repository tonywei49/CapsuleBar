import AppKit
import Combine

struct AppInfo: Identifiable {
    let id: pid_t
    let app: NSRunningApplication
    let name: String
    let bundleID: String?
    let isMenuBarApp: Bool      // accessory policy: no Dock icon, usually lives in the menu bar
    let isActive: Bool
    let isHidden: Bool
    let isSystem: Bool          // background UI agent shipped with macOS (Control Center, WindowManager…)
    var usage: AppUsage
}

enum SortKey: String, CaseIterable {
    case cpu, memory, name
}

/// Publishes the running apps and system load on a configurable interval, which apps have a
/// menu bar extra, and which apps have been using too much CPU for too long.
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var system = SystemStats()
    /// Apps known to have a status item. Only meaningful while `extrasKnown` is true.
    @Published private(set) var menuExtraPIDs: Set<pid_t> = []
    @Published private(set) var extrasKnown = false
    /// Apps above the alert threshold for at least the alert duration.
    @Published private(set) var hotPIDs: Set<pid_t> = []

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "capsulebar.sampler", qos: .utility)
    private let axQueue = DispatchQueue(label: "capsulebar.ax", qos: .utility)
    private let processSampler = ProcessSampler()   // only touched on `queue`
    private let systemSampler = SystemSampler()     // only touched on `queue`
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var extraCheckedAt: [pid_t: Date] = [:]
    private var probing = false
    private var hotSince: [pid_t: Date] = [:]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        refresh()
        scheduleTimer(interval: settings.sampleInterval)
        settings.$sampleInterval
            .dropFirst()
            .sink { [weak self] interval in
                MainActor.assumeIsolated { self?.scheduleTimer(interval: interval) }
            }
            .store(in: &cancellables)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && !$0.isTerminated
                && $0.processIdentifier > 0 && $0.processIdentifier != ownPID
        }
        // Helper apps nested inside another running app's bundle (e.g. "Quark Helper" inside
        // Quark.app) are folded into their parent instead of being listed on their own.
        let bundlePaths = Set(candidates.compactMap { $0.bundleURL?.path })
        let running = candidates.filter { app in
            guard let path = app.bundleURL?.path else { return true }
            return !bundlePaths.contains { other in other != path && path.hasPrefix(other + "/") }
        }
        let descriptors = running.map { AppDescriptor(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path) }
        let processSampler = processSampler
        let systemSampler = systemSampler
        queue.async { [weak self] in
            let usage = processSampler.sample(apps: descriptors)
            let stats = systemSampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(running: running, usage: usage, stats: stats)
                }
            }
        }
    }

    private func apply(running: [NSRunningApplication], usage: [pid_t: AppUsage], stats: SystemStats) {
        system = stats
        apps = running.compactMap { app in
            guard !app.isTerminated else { return nil }
            let pid = app.processIdentifier
            return AppInfo(
                id: pid,
                app: app,
                name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)",
                bundleID: app.bundleIdentifier,
                isMenuBarApp: app.activationPolicy == .accessory,
                isActive: app.isActive,
                isHidden: app.isHidden,
                isSystem: app.activationPolicy == .accessory && (app.bundleURL?.path.hasPrefix("/System/") ?? false),
                usage: usage[pid] ?? AppUsage()
            )
        }
        updateHot()
        probeMenuExtras()
    }

    // MARK: High CPU

    private func updateHot() {
        guard settings.alertEnabled else {
            hotSince = [:]
            if !hotPIDs.isEmpty { hotPIDs = [] }
            return
        }
        let now = Date()
        var next: [pid_t: Date] = [:]
        for app in apps where !app.isSystem && app.usage.cpuPercent >= settings.alertThreshold {
            next[app.id] = hotSince[app.id] ?? now
        }
        hotSince = next
        let hot = Set(next.filter { now.timeIntervalSince($0.value) >= settings.alertDuration }.keys)
        if hot != hotPIDs { hotPIDs = hot }
    }

    // MARK: Menu bar extras

    /// Re-checks apps whose status-item info is unknown or older than 20 s, off the main thread.
    private func probeMenuExtras() {
        guard MenuExtras.isTrusted else {
            if extrasKnown { extrasKnown = false }
            return
        }
        guard !probing else { return }
        let now = Date()
        let alive = Set(apps.map(\.id))
        extraCheckedAt = extraCheckedAt.filter { alive.contains($0.key) }
        let stale = apps.map(\.id).filter { extraCheckedAt[$0].map { now.timeIntervalSince($0) > 20 } ?? true }
        guard !stale.isEmpty else { return }
        probing = true
        axQueue.async { [weak self] in
            let found = Set(stale.filter { MenuExtras.hasItems(pid: $0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let checked = Date()
                    for pid in stale { self.extraCheckedAt[pid] = checked }
                    var next = self.menuExtraPIDs.subtracting(stale).union(found)
                    next.formIntersection(Set(self.apps.map(\.id)))
                    if next != self.menuExtraPIDs { self.menuExtraPIDs = next }
                    if !self.extrasKnown { self.extrasKnown = true }
                    self.probing = false
                }
            }
        }
    }

    /// true / false when known, nil when Accessibility is not granted yet.
    func hasMenuBarExtra(_ pid: pid_t) -> Bool? {
        extrasKnown ? menuExtraPIDs.contains(pid) : nil
    }

    // MARK: Queries

    func sorted(by key: SortKey, includeSystem: Bool = true) -> [AppInfo] {
        let apps = includeSystem ? self.apps : self.apps.filter { !$0.isSystem }
        switch key {
        case .cpu: return apps.sorted { $0.usage.cpuPercent > $1.usage.cpuPercent }
        case .memory: return apps.sorted { $0.usage.memoryBytes > $1.usage.memoryBytes }
        case .name: return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func runningApp(bundleID: String) -> AppInfo? {
        apps.first { $0.bundleID == bundleID }
    }

    var hotApps: [AppInfo] {
        apps.filter { hotPIDs.contains($0.id) }.sorted { $0.usage.cpuPercent > $1.usage.cpuPercent }
    }
}
