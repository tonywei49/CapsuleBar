import ApplicationServices
import Foundation

/// Accessibility helpers for an app's menu bar extras (status items). Thread-safe; callers
/// may use it off the main thread.
enum MenuExtras {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app's status items, in menu bar order. Empty when it has none or AX is unavailable.
    static func items(pid: pid_t, timeout: Float = 0.5) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, timeout)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barValue) == .success,
              let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return [] }
        let bar = barValue as! AXUIElement   // type checked above
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement] else { return [] }
        return items
    }

    static func hasItems(pid: pid_t) -> Bool {
        !items(pid: pid, timeout: 0.3).isEmpty
    }
}
