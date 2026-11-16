import AppKit
import Combine

/// Bundle IDs the user pinned to the collapsed capsule, persisted in UserDefaults.
@MainActor
final class PinStore: ObservableObject {
    static let maxPins = 4
    private static let key = "pinnedBundleIDs"

    @Published private(set) var bundleIDs: [String]
    private var iconCache: [String: NSImage] = [:]

    init() {
        bundleIDs = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func isPinned(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// Returns an error message when the pin limit is reached.
    func toggle(_ bundleID: String) -> String? {
        if let index = bundleIDs.firstIndex(of: bundleID) {
            bundleIDs.remove(at: index)
        } else {
            guard bundleIDs.count < Self.maxPins else { return "最多只能釘選 \(Self.maxPins) 個 App" }
            bundleIDs.append(bundleID)
        }
        UserDefaults.standard.set(bundleIDs, forKey: Self.key)
        return nil
    }

    func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Icon for a pinned app that may not be running.
    func icon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[bundleID] = icon
        return icon
    }
}
