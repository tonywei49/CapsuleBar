import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var monitor = ProcessMonitor(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private let pins = PinStore()
    private var controllers: [CapsuleController] = []
    private var clickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var screenModeCancellable: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        rebuildCapsules()

        screenModeCancellable = settings.$screenMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published emits before the value is stored; rebuild on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuildCapsules() } }
            }

        if CommandLine.arguments.contains("--settings") {
            settingsWindow.show()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildCapsules() }
        }

        // Clicks in other apps collapse every expanded capsule.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.collapse() } }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let delay = Double(ProcessInfo.processInfo.environment["CAPSULE_SNAPSHOT_DELAY"] ?? "") ?? 4.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.runSnapshot(dir: dir) }
            }
        }

        if CommandLine.arguments.contains("--axprobe") {
            // Debug: which running apps expose a menu bar extra through Accessibility.
            print("AXPROBE trusted=\(AXIsProcessTrusted())")
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.5)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success,
                      let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                print("AXPROBE \(app.localizedName ?? "?") extras=\((children as? [AXUIElement])?.count ?? 0)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }

        if CommandLine.arguments.contains("--enable-login-item") {
            // Registers this copy of the app as a login item and reports the result.
            do {
                try SMAppService.mainApp.register()
                print("LOGINITEM registered status=\(SMAppService.mainApp.status.rawValue)")
            } catch {
                print("LOGINITEM error \(error.localizedDescription) status=\(SMAppService.mainApp.status.rawValue)")
            }
            fflush(stdout)
        }

        if CommandLine.arguments.contains("--rightclick-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.runRightClickTest() }
            }
        }

        if CommandLine.arguments.contains("--selftest") {
            Task { await runSelfTest() }
        }

        // Debug hook: `CapsuleBar --expanded` opens the capsule on the main screen at launch.
        if CommandLine.arguments.contains("--expanded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated { self?.controllers.first?.expand(reason: "--expanded") }
            }
        }
    }

    /// Debug: `CapsuleBar --snapshot DIR` writes collapsed/expanded PNGs per screen plus a
    /// text report with frames and the top apps, then quits.
    private func runSnapshot(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String] = []
        for (i, c) in controllers.enumerated() {
            report.append("collapsed[\(i)] " + c.snapshot(to: dir.appendingPathComponent("screen\(i)-collapsed.png")))
        }
        controllers.first?.expand(reason: "snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            MainActor.assumeIsolated {
                if let c = controllers.first {
                    report.append("expanded[0] " + c.snapshot(to: dir.appendingPathComponent("screen0-expanded.png")))
                }
                report.append(String(format: "system cpu=%.1f%% mem=%.2fGB/%.2fGB", monitor.system.cpuPercent,
                                     Double(monitor.system.memoryUsed) / 1e9, Double(monitor.system.memoryTotal) / 1e9))
                report.append("extrasKnown=\(monitor.extrasKnown) withExtras=" +
                              monitor.apps.filter { monitor.menuExtraPIDs.contains($0.id) }.map(\.name).joined(separator: ","))
                report.append("hot=" + monitor.hotApps.map(\.name).joined(separator: ","))
                settingsWindow.show()
                for app in monitor.sorted(by: .cpu, includeSystem: false).prefix(8) {
                    report.append(String(format: "%@ pid=%d cpu=%.1f%% mem=%.0fMB procs=%d", app.name, app.id,
                                         app.usage.cpuPercent, Double(app.usage.memoryBytes) / 1e6, app.usage.processCount))
                }
                try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"),
                                                          atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                    MainActor.assumeIsolated {
                        if let n = settingsWindow.windowNumber {
                            captureWindow(n, to: dir.appendingPathComponent("settings.png"))
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Debug: exercises launch / relaunch / quit / force quit on Calculator, then quits.
    private func runSelfTest() async {
        let id = "com.apple.calculator"
        func running() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func log(_ s: String) { print("SELFTEST " + s); fflush(stdout) }

        log("launch: \(await AppActions.launch(bundleID: id) ?? "ok")")
        await wait(2)
        guard let first = running() else { log("FAIL not running after launch"); NSApp.terminate(nil); return }
        log("running pid=\(first.processIdentifier)")
        log("relaunch: \(await AppActions.relaunch(first) ?? "ok")")
        await wait(2)
        let second = running()
        log("after relaunch pid=\(second.map { String($0.processIdentifier) } ?? "none") (old \(first.processIdentifier))")
        if let second {
            log("quit: \(AppActions.quit(second) ?? "ok")")
            await wait(2)
            log("after quit running=\(running() != nil)")
        }
        _ = await AppActions.launch(bundleID: id)
        await wait(2)
        if let third = running() {
            log("forceQuit: \(AppActions.forceQuit(third) ?? "ok")")
            await wait(1)
            log("after forceQuit running=\(running() != nil)")
        }
        log("AX trusted=\(AXIsProcessTrusted())")
        NSApp.terminate(nil)
    }

    /// Debug: posts real right clicks (through the window server) on the main screen's capsule
    /// and on its first pinned icon, closing each menu with Escape, then restores the cursor.
    private func runRightClickTest() {
        guard let controller = controllers.first, let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let saved = NSEvent.mouseLocation
        let frame = controller.debugPanelFrame
        func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }
        func rightClick(_ p: NSPoint) {
            let point = cg(p)
            print("RCTEST right click at \(point)"); fflush(stdout)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
        func escape() {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        }
        var steps: [(Double, () -> Void)] = []
        // 1) empty part of the capsule (right edge of the right wing)
        steps.append((0, { rightClick(NSPoint(x: frame.maxX - 6, y: frame.midY)) }))
        steps.append((1.2, escape))
        // 2) first pinned icon, if any
        if let pin = controller.state.pinFrames.first {
            print("RCTEST pin \(pin.key) frame=\(pin.value)")
            let p = NSPoint(x: frame.minX + pin.value.midX, y: frame.maxY - pin.value.midY)
            steps.append((2.4, { rightClick(p) }))
            steps.append((3.8, escape))
        } else {
            print("RCTEST no pins")
        }
        steps.append((4.6, {
            CGWarpMouseCursorPosition(cg(saved))
            print("RCTEST done"); fflush(stdout)
            NSApp.terminate(nil)
        }))
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { step() } }
        }
    }

    private func rebuildCapsules() {
        controllers.forEach { $0.close() }
        controllers = screensForCapsules().map { screen in
            let controller = CapsuleController(screen: screen, monitor: monitor, pins: pins)
            controller.onExpand = { [weak self] expanding in
                self?.controllers.filter { $0 !== expanding }.forEach { $0.collapse() }
            }
            controller.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
            return controller
        }
    }

    private func screensForCapsules() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let main = screens.first else { return [] }   // first = the one with the menu bar
        switch settings.screenMode {
        case .all:
            return screens
        case .mainOnly:
            return [main]
        case .notchOnly:
            // Fall back to the main screen when no notched screen is attached (e.g. lid closed).
            let notched = screens.filter { $0.safeAreaInsets.top > 0 }
            return notched.isEmpty ? [main] : notched
        }
    }
}

@main
enum CapsuleBarMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
