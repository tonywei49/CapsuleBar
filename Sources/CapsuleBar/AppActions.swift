import AppKit
import ApplicationServices

/// Controls other apps. Every call returns a user-facing error message, or nil on success.
@MainActor
enum AppActions {
    static func bringToFront(_ app: NSRunningApplication) async -> String? {
        if app.isHidden { app.unhide() }
        // Since macOS 14 activation is cooperative: activate() from a background app may be
        // ignored, while opening the app's bundle behaves like clicking it in the Dock.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                return nil
            } catch {
                // fall through to activate()
            }
        }
        return app.activate() ? nil : "無法切換到「\(app.localizedName ?? "")」"
    }

    static func toggleHidden(_ app: NSRunningApplication) -> String? {
        let ok = app.isHidden ? app.unhide() : app.hide()
        return ok ? nil : "這個 App 不支援隱藏"
    }

    static func quit(_ app: NSRunningApplication) -> String? {
        app.terminate() ? nil : "「\(app.localizedName ?? "")」拒絕結束"
    }

    static func forceQuit(_ app: NSRunningApplication) -> String? {
        app.forceTerminate() ? nil : "無法強制結束「\(app.localizedName ?? "")」"
    }

    static func relaunch(_ app: NSRunningApplication) async -> String? {
        let name = app.localizedName ?? ""
        guard let url = app.bundleURL else { return "找不到「\(name)」的位置，無法重新啟動" }
        guard app.terminate() else { return "「\(name)」拒絕結束" }
        for _ in 0..<50 where !app.isTerminated {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard app.isTerminated else { return "「\(name)」沒有在 10 秒內結束（可能正在詢問是否存檔）" }
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return nil
        } catch {
            return "重新開啟「\(name)」失敗：\(error.localizedDescription)"
        }
    }

    static func launch(bundleID: String) async -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "找不到 \(bundleID)"
        }
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return "開啟失敗：\(error.localizedDescription)"
        }
    }

    /// Opens the app's own menu bar extra (status item) menu through the Accessibility API.
    static func openMenuBarExtra(_ app: NSRunningApplication) -> String? {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            return "需要輔助使用權限：系統設定 › 隱私權與安全性 › 輔助使用，允許 CapsuleBar 後再試一次"
        }
        guard let first = MenuExtras.items(pid: app.processIdentifier, timeout: 1.0).first else {
            return "「\(app.localizedName ?? "")」沒有選單列圖示"
        }
        let result = AXUIElementPerformAction(first, kAXPressAction as CFString)
        // While its menu is open the app is busy tracking it and the press times out
        // (kAXErrorCannotComplete) even though it worked: check for the menu window instead.
        if result == .success || (result == .cannotComplete && hasOpenMenu(pid: app.processIdentifier)) {
            return nil
        }
        return "打開選單失敗（AX 錯誤 \(result.rawValue)）"
    }

    /// True when the process has a pop-up menu window on screen (window list metadata needs no
    /// Screen Recording permission).
    static func hasOpenMenu(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }
}
