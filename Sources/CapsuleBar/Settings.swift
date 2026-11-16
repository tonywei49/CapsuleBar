import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// User preferences that code outside SwiftUI views reacts to, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    enum ScreenMode: String, CaseIterable {
        case all, notchOnly, mainOnly

        var title: String {
            switch self {
            case .all: return "所有螢幕"
            case .notchOnly: return "只有內建螢幕（瀏海）"
            case .mainOnly: return "只有主螢幕"
            }
        }
    }

    static let intervalOptions: [(String, Double)] = [("1 秒", 1), ("2 秒", 2), ("5 秒", 5)]
    static let thresholdOptions: [(String, Double)] = [("50%", 50), ("80%", 80), ("100%（一核滿載）", 100), ("200%", 200)]
    static let durationOptions: [(String, Double)] = [("10 秒", 10), ("30 秒", 30), ("1 分鐘", 60), ("3 分鐘", 180)]

    private let defaults = UserDefaults.standard

    @Published var sampleInterval: Double { didSet { defaults.set(sampleInterval, forKey: "sampleInterval") } }
    @Published var screenMode: ScreenMode { didSet { defaults.set(screenMode.rawValue, forKey: "screenMode") } }
    @Published var alertEnabled: Bool { didSet { defaults.set(alertEnabled, forKey: "alertEnabled") } }
    @Published var alertThreshold: Double { didSet { defaults.set(alertThreshold, forKey: "alertThreshold") } }
    @Published var alertDuration: Double { didSet { defaults.set(alertDuration, forKey: "alertDuration") } }

    init() {
        defaults.register(defaults: [
            "sampleInterval": 2.0, "screenMode": ScreenMode.all.rawValue,
            "alertEnabled": true, "alertThreshold": 80.0, "alertDuration": 30.0,
        ])
        sampleInterval = defaults.double(forKey: "sampleInterval")
        screenMode = ScreenMode(rawValue: defaults.string(forKey: "screenMode") ?? "") ?? .all
        alertEnabled = defaults.bool(forKey: "alertEnabled")
        alertThreshold = defaults.double(forKey: "alertThreshold")
        alertDuration = defaults.double(forKey: "alertDuration")
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CapsuleBar 設定"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @AppStorage(CapsuleStyle.tintKey) private var tint: Double = CapsuleStyle.defaultTint
    @AppStorage("showSystemApps") private var showSystemApps = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var axTrusted = MenuExtras.isTrusted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("一般") {
                Toggle("登入時自動啟動", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("需要在系統設定的「登入項目」中允許").font(.caption).foregroundStyle(.orange)
                        Button("打開") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Picker("膠囊顯示於", selection: $settings.screenMode) {
                    ForEach(AppSettings.ScreenMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("膠囊顏色", selection: $tint) {
                    ForEach(CapsuleStyle.options, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("更新頻率", selection: $settings.sampleInterval) {
                    ForEach(AppSettings.intervalOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("清單顯示系統元件", isOn: $showSystemApps)
            }

            Section {
                Toggle("啟用高 CPU 警示", isOn: $settings.alertEnabled)
                Picker("CPU 超過", selection: $settings.alertThreshold) {
                    ForEach(AppSettings.thresholdOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                .disabled(!settings.alertEnabled)
                Picker("持續", selection: $settings.alertDuration) {
                    ForEach(AppSettings.durationOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                .disabled(!settings.alertEnabled)
            } header: {
                Text("高 CPU 警示")
            } footer: {
                Text("某個 App 持續超過門檻時，膠囊邊緣會閃爍紅光。100% 代表一個 CPU 核心滿載。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("權限") {
                HStack {
                    Label(axTrusted ? "輔助使用：已允許" : "輔助使用：未允許",
                          systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Spacer()
                    if !axTrusted {
                        Button("打開系統設定") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Text("用來打開其他 App 的選單列選單。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("CapsuleBar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("結束 CapsuleBar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onReceive(poll) { _ in
            axTrusted = MenuExtras.isTrusted
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "設定失敗：\(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
