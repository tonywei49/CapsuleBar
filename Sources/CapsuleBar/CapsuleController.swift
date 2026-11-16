import AppKit
import Combine
import SwiftUI

/// Borderless panel that may sit on top of the menu bar.
final class CapsulePanel: NSPanel {
    /// Gets right clicks first; return true when handled.
    var onRightMouseDown: ((NSPoint) -> Bool)?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, onRightMouseDown?(event.locationInWindow) == true { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum AppCommand {
    case bringToFront, toggleHidden, quit, requestForceQuit, confirmForceQuit, cancelForceQuit
    case relaunch, openMenuBarExtra, togglePin
}

@MainActor
final class CapsuleState: ObservableObject {
    @Published var isExpanded = false
    @Published var collapsedSize: CGSize
    @Published var expandedSize: CGSize
    @Published var message: String?
    @Published var pendingForceQuit: pid_t?
    @Published var busy: Set<pid_t> = []
    /// Pinned icon frames in the hosting view (top-left origin), for right-click hit testing.
    var pinFrames: [String: CGRect] = [:]
    let geometry: CapsuleGeometry

    static let toastHeight: CGFloat = 30

    /// Size of the black shape (and the window) for the current state. While collapsed, a
    /// message grows the capsule downward into a small toast.
    var shapeSize: CGSize {
        if isExpanded { return expandedSize }
        if message != nil {
            return CGSize(width: max(collapsedSize.width, 420), height: collapsedSize.height + Self.toastHeight)
        }
        return collapsedSize
    }

    init(geometry: CapsuleGeometry, pinCount: Int) {
        self.geometry = geometry
        collapsedSize = geometry.collapsedSize(pinCount: pinCount)
        expandedSize = geometry.expandedSize(pinCount: pinCount)
    }
}

/// One capsule on one screen: owns the panel and handles commands from its views.
@MainActor
final class CapsuleController {
    let state: CapsuleState
    private let panel: CapsulePanel
    private let monitor: ProcessMonitor
    private let pins: PinStore
    private var cancellables: Set<AnyCancellable> = []
    private var messageTask: Task<Void, Never>?
    var onExpand: ((CapsuleController) -> Void)?
    var onOpenSettings: (() -> Void)?

    private static let animation = Animation.spring(response: 0.38, dampingFraction: 0.82)

    init(screen: NSScreen, monitor: ProcessMonitor, pins: PinStore) {
        self.monitor = monitor
        self.pins = pins
        let geometry = CapsuleGeometry(screen: screen)
        state = CapsuleState(geometry: geometry, pinCount: pins.bundleIDs.count)

        panel = CapsulePanel(contentRect: geometry.frame(for: state.collapsedSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = CapsuleRootView(state: state, monitor: monitor, pins: pins, controller: self)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onRightMouseDown = { [weak self] point in
            MainActor.assumeIsolated { self?.handleRightClick(at: point) ?? false }
        }
        panel.orderFrontRegardless()

        pins.$bundleIDs
            .dropFirst()
            .sink { [weak self] ids in
                MainActor.assumeIsolated { self?.pinsChanged(count: ids.count) }
            }
            .store(in: &cancellables)
    }

    /// Debug: renders the panel's current content to a PNG and describes its frame.
    func snapshot(to url: URL) -> String {
        captureWindow(panel.windowNumber, to: url)
        let g = state.geometry
        return "screen=\(g.screenFrame) notch=\(g.hasNotch) notchWidth=\(g.notchWidth) bar=\(g.barHeight) panel=\(panel.frame)"
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Expand / collapse

    func toggle() {
        state.isExpanded ? collapse() : expand()
    }

    func expand(reason: String = "tap") {
        guard !state.isExpanded else { return }
        NSLog("CapsuleBar expand (%@) on screen %@", reason, NSStringFromRect(state.geometry.screenFrame))
        onExpand?(self)
        monitor.refresh()
        withAnimation(Self.animation) { state.isExpanded = true }
        syncFrame()
    }

    func collapse() {
        guard state.isExpanded else { return }
        state.pendingForceQuit = nil
        withAnimation(Self.animation) { state.isExpanded = false }
        syncFrame()
    }

    private func pinsChanged(count: Int) {
        withAnimation(Self.animation) {
            state.collapsedSize = state.geometry.collapsedSize(pinCount: count)
            state.expandedSize = state.geometry.expandedSize(pinCount: count)
        }
        syncFrame()
    }

    /// Resizes the window to the shape. Growing happens at once so the animation has room;
    /// shrinking waits until the animation is done.
    private func syncFrame() {
        let target = state.geometry.frame(for: state.shapeSize)
        let current = panel.frame
        if target.width >= current.width && target.height >= current.height {
            panel.setFrame(target, display: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.setFrame(self.state.geometry.frame(for: self.state.shapeSize), display: true)
            }
        }
    }

    // MARK: Commands

    func show(_ message: String?) {
        guard let message else { return }
        messageTask?.cancel()
        withAnimation(Self.animation) { state.message = message }
        syncFrame()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.animation) { self.state.message = nil }
            self.syncFrame()
        }
    }

    func launchPinned(_ bundleID: String) {
        Task {
            if let running = monitor.runningApp(bundleID: bundleID) {
                show(await AppActions.bringToFront(running.app))
            } else {
                show(await AppActions.launch(bundleID: bundleID))
            }
        }
    }

    var debugPanelFrame: NSRect { panel.frame }

    // MARK: Right click

    /// Collapsed capsule: right-click a pinned icon to open its menu bar menu, anywhere else for a
    /// menu of every app that has a menu bar icon. Expanded: let SwiftUI context menus handle it.
    private func handleRightClick(at windowPoint: NSPoint) -> Bool {
        guard !state.isExpanded, let view = panel.contentView else { return false }
        let point = CGPoint(x: windowPoint.x, y: view.bounds.height - windowPoint.y)
        if let id = state.pinFrames.first(where: { $0.value.insetBy(dx: -3, dy: -4).contains(point) })?.key {
            NSLog("CapsuleBar right click on pin %@", id)
            openPinnedMenu(id)
        } else {
            NSLog("CapsuleBar right click on capsule")
            showMenuBarAppsMenu(at: windowPoint, in: view)
        }
        return true
    }

    private var menuTarget: MenuTarget?

    private func showMenuBarAppsMenu(at windowPoint: NSPoint, in view: NSView) {
        let menu = NSMenu()
        let target = MenuTarget()
        menuTarget = target
        let header = NSMenuItem(title: "選單列程式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !MenuExtras.isTrusted {
            menu.addItem(target.item("需要輔助使用權限…") { [weak self] in self?.onOpenSettings?() })
        } else {
            let apps = monitor.apps
                .filter { monitor.menuExtraPIDs.contains($0.id) && !$0.isSystem }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if apps.isEmpty {
                let none = NSMenuItem(title: "（找不到）", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for info in apps {
                let item = target.item(info.name) { [weak self] in
                    self?.show(AppActions.openMenuBarExtra(info.app))
                }
                if let icon = info.app.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(target.item("展開所有程式") { [weak self] in self?.expand() })
        menu.addItem(target.item("設定…") { [weak self] in self?.onOpenSettings?() })
        menu.popUp(positioning: nil, at: view.convert(windowPoint, from: nil), in: view)
    }

    /// Right-click on a pinned icon: open that app's menu bar extra.
    func openPinnedMenu(_ bundleID: String) {
        guard let running = monitor.runningApp(bundleID: bundleID) else {
            show("「\(pins.displayName(for: bundleID))」沒有在執行")
            return
        }
        show(AppActions.openMenuBarExtra(running.app))
    }

    func openSettings() {
        collapse()
        onOpenSettings?()
    }

    func perform(_ command: AppCommand, on info: AppInfo) {
        let app = info.app
        switch command {
        case .bringToFront:
            collapse()
            Task { show(await AppActions.bringToFront(app)) }
        case .toggleHidden:
            show(AppActions.toggleHidden(app))
        case .quit:
            show(AppActions.quit(app))
        case .requestForceQuit:
            state.pendingForceQuit = info.id
        case .cancelForceQuit:
            state.pendingForceQuit = nil
        case .confirmForceQuit:
            state.pendingForceQuit = nil
            show(AppActions.forceQuit(app))
        case .relaunch:
            state.busy.insert(info.id)
            Task {
                let error = await AppActions.relaunch(app)
                state.busy.remove(info.id)
                show(error ?? "已重新啟動「\(info.name)」")
            }
        case .openMenuBarExtra:
            collapse()
            // Let the collapse animation clear the area before the menu pops up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.show(AppActions.openMenuBarExtra(app)) }
            }
        case .togglePin:
            if let id = info.bundleID {
                let wasPinned = pins.isPinned(id)
                show(pins.toggle(id) ?? (wasPinned ? "已取消釘選「\(info.name)」" : "已釘選「\(info.name)」到膠囊，右鍵點它可打開選單"))
            }
        }
        monitor.refresh()
    }
}

/// Debug: captures one of our own windows to PNG. Capturing our own windows needs no Screen
/// Recording permission. The symbol is hidden from Swift on recent SDKs, so look it up at runtime.
func captureWindow(_ windowNumber: Int, to url: URL) {
    typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
    let create = unsafeBitCast(sym, to: CreateImage.self)
    // .optionIncludingWindow = 8, .boundsIgnoreFraming | .bestResolution = 9
    guard let image = create(.null, 8, UInt32(windowNumber), 9)?.takeRetainedValue() else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
}

/// Target object for NSMenu items backed by closures.
@MainActor
final class MenuTarget: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
