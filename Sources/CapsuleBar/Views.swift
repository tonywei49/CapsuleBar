import AppKit
import SwiftUI

// MARK: - Shape

/// Flush with the top edge, flared "ears" at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func cpuColor(_ value: Double) -> Color {
        value >= 100 ? .red : value >= 40 ? .orange : .white.opacity(0.85)
    }
}

// MARK: - Root

struct CapsuleRootView: View {
    @ObservedObject var state: CapsuleState
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var pins: PinStore
    let controller: CapsuleController
    @AppStorage(CapsuleStyle.tintKey) private var tint: Double = CapsuleStyle.defaultTint

    var body: some View {
        let size = state.shapeSize
        let ear: CGFloat = state.isExpanded ? 12 : 6
        let shape = NotchShape(topRadius: ear, bottomRadius: state.isExpanded ? 22 : 11)
        ZStack(alignment: .top) {
            ZStack {
                if tint < 1 {
                    VisualEffectBackground()
                }
                Color.black.opacity(tint)
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(tint < 1 ? 0.10 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(state.isExpanded ? 0.35 : 0), radius: 14, y: 6)
            .overlay {
                if !state.isExpanded && !monitor.hotPIDs.isEmpty {
                    HotGlow(shape: shape)
                }
            }

            VStack(spacing: 0) {
                if state.isExpanded {
                    ExpandedView(state: state, monitor: monitor, pins: pins, controller: controller)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    CollapsedView(state: state, monitor: monitor, pins: pins, controller: controller)
                        .frame(height: state.collapsedSize.height)
                        .transition(.opacity)
                    if let message = state.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 18)
                            .frame(height: CapsuleState.toastHeight - 6)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, ear)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @ObservedObject var state: CapsuleState
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var pins: PinStore
    let controller: CapsuleController

    var body: some View {
        let geometry = state.geometry
        let wing = geometry.wingWidth(pinCount: pins.bundleIDs.count)
        let cpu = monitor.system.cpuPercent
        let memory = monitor.system.memoryPercent
        let hot = monitor.hotApps
        HStack(spacing: 0) {
            // Left wing: pinned apps, then CPU
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(pins.bundleIDs, id: \.self) { id in
                    PinnedIcon(bundleID: id, running: monitor.runningApp(bundleID: id), pins: pins,
                               action: { controller.launchPinned(id) })
                }
                RingGauge(value: cpu, tint: !hot.isEmpty || cpu >= 90 ? .red : cpu >= 60 ? .orange : .green,
                          help: "CPU \(Format.percent(cpu))")
                    .padding(.leading, pins.bundleIDs.isEmpty ? 0 : 2)
            }
            .padding(.trailing, 8)
            .frame(width: wing)

            Color.clear.frame(width: geometry.hasNotch ? geometry.notchWidth : 8, height: 1)

            // Right wing: memory
            HStack(spacing: 0) {
                RingGauge(value: memory, tint: memory >= 85 ? .orange : .cyan,
                          help: "記憶體 \(Format.percent(memory))")
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: wing)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggle() }
        .onPreferenceChange(PinFramesKey.self) { frames in
            MainActor.assumeIsolated { state.pinFrames = frames }
        }
        .help(hot.isEmpty ? "左鍵：展開所有程式　右鍵：選單列程式"
              : "CPU 持續偏高：" + hot.map { "\($0.name) \(Format.percent($0.usage.cpuPercent))" }.joined(separator: "、") + "\n點一下查看")
    }
}

/// Tiny ring + number, used in the collapsed capsule.
struct RingGauge: View {
    let value: Double   // percent
    let tint: Color
    let help: String

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: min(max(value / 100, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text(String(format: "%.0f", min(value, 999)))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(minWidth: 18, alignment: .leading)
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.4), value: value)
        .help(help)
    }
}

/// Behind-window blur for the translucent capsule.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

enum CapsuleStyle {
    static let tintKey = "capsuleTint"
    static let defaultTint = 0.45
    static let options: [(String, Double)] = [("很透明", 0.2), ("半透明", 0.45), ("較深", 0.7), ("不透明", 1.0)]
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

struct PinnedIcon: View {
    let bundleID: String
    let running: AppInfo?
    @ObservedObject var pins: PinStore
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: running?.app.icon ?? pins.icon(for: bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .opacity(running == nil ? 0.4 : 1)
                .scaleEffect(hovering ? 1.15 : 1)
                .overlay(alignment: .bottom) {
                    if running != nil {
                        Circle().fill(.white.opacity(0.8)).frame(width: 3, height: 3).offset(y: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PinFramesKey.self, value: [bundleID: proxy.frame(in: .global)])
        })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(running?.name ?? pins.displayName(for: bundleID))\n左鍵：切換／開啟　右鍵：打開選單列選單")
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var state: CapsuleState
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var pins: PinStore
    let controller: CapsuleController
    @AppStorage("sortKey") private var sortKey: SortKey = .cpu
    @AppStorage("showSystemApps") private var showSystemApps = false
    @AppStorage(CapsuleStyle.tintKey) private var tint: Double = CapsuleStyle.defaultTint

    var body: some View {
        VStack(spacing: 0) {
            // Top strip sits behind the notch / menu bar: clicking it collapses.
            Color.clear
                .frame(height: state.collapsedSize.height)
                .contentShape(Rectangle())
                .onTapGesture { controller.collapse() }

            header
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)

            columnHeader
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(monitor.sorted(by: sortKey, includeSystem: showSystemApps)) { info in
                        ProcessRow(info: info, state: state, pins: pins, controller: controller,
                                   hasMenuBarExtra: monitor.hasMenuBarExtra(info.id),
                                   isHot: monitor.hotPIDs.contains(info.id))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            if let message = state.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.08))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 14) {
            StatPill(icon: "cpu", title: "CPU", value: Format.percent(monitor.system.cpuPercent),
                     fraction: monitor.system.cpuPercent / 100)
            StatPill(icon: "memorychip", title: "記憶體",
                     value: "\(Format.bytes(monitor.system.memoryUsed)) / \(Format.bytes(monitor.system.memoryTotal))",
                     fraction: monitor.system.memoryPercent / 100)
            Spacer()
            Text("\(monitor.sorted(by: sortKey, includeSystem: showSystemApps).count) 個 App")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Picker("膠囊顏色", selection: $tint) {
                    ForEach(CapsuleStyle.options, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                Toggle("顯示系統元件", isOn: $showSystemApps)
                Divider()
                Button("設定…") { controller.openSettings() }
                Button("結束 CapsuleBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("設定")
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            sortButton("App", key: .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("CPU", key: .cpu).frame(width: 60, alignment: .trailing)
            sortButton("記憶體", key: .memory).frame(width: 76, alignment: .trailing)
            Color.clear.frame(width: 58, height: 1)
        }
        .padding(.leading, 34)
    }

    private func sortButton(_ title: String, key: SortKey) -> some View {
        Button {
            sortKey = key
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key { Image(systemName: key == .name ? "chevron.up" : "chevron.down") }
            }
            .font(.system(size: 10, weight: sortKey == key ? .semibold : .regular))
            .foregroundStyle(sortKey == key ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct StatPill: View {
    let icon: String
    let title: String
    let value: String
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).foregroundStyle(.secondary)
                    Text(value).foregroundStyle(.white)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(fraction >= 0.85 ? Color.orange : Color.white.opacity(0.75))
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 3)
            }
            .frame(width: title == "CPU" ? 80 : 150)
        }
    }
}

// MARK: - Row

struct ProcessRow: View {
    let info: AppInfo
    @ObservedObject var state: CapsuleState
    @ObservedObject var pins: PinStore
    let controller: CapsuleController
    let hasMenuBarExtra: Bool?      // nil = unknown (Accessibility not granted)
    let isHot: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if state.pendingForceQuit == info.id {
                confirmForceQuit
            } else {
                row
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHot ? Color.red.opacity(hovering ? 0.22 : 0.14) : Color.white.opacity(hovering ? 0.08 : 0))
        )
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var subtitle: String {
        var parts: [String] = []
        if isHot { parts.append("CPU 持續偏高") }
        if hasMenuBarExtra ?? info.isMenuBarApp { parts.append("選單列") }
        if info.isActive { parts.append("前景") }
        if info.isHidden { parts.append("已隱藏") }
        if info.usage.processCount > 1 { parts.append("\(info.usage.processCount) 個程序") }
        return parts.joined(separator: " · ")
    }

    private var row: some View {
        HStack(spacing: 0) {
            Image(nsImage: info.app.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(info.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if pins.isPinned(info.bundleID) {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10))
                        .foregroundStyle(isHot ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { controller.perform(.bringToFront, on: info) }

            Text(Format.percent(info.usage.cpuPercent))
                .foregroundStyle(Format.cpuColor(info.usage.cpuPercent))
                .frame(width: 60, alignment: .trailing)
            Text(Format.bytes(info.usage.memoryBytes))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 76, alignment: .trailing)

            HStack(spacing: 6) {
                if state.busy.contains(info.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        controller.perform(.quit, on: info)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(hovering ? 0.75 : 0))
                    .help("結束")
                    actionsMenu
                }
            }
            .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
    }

    @ViewBuilder
    private var menuItems: some View {
            Button("切換到前景") { controller.perform(.bringToFront, on: info) }
            Button(info.isHidden ? "取消隱藏" : "隱藏") { controller.perform(.toggleHidden, on: info) }
            if hasMenuBarExtra != false {
                Button("打開選單列選單") { controller.perform(.openMenuBarExtra, on: info) }
            }
            Divider()
            if info.bundleID != nil {
                Button(pins.isPinned(info.bundleID) ? "取消釘選" : "釘選到膠囊") {
                    controller.perform(.togglePin, on: info)
                }
                Divider()
            }
            Button("重新啟動") { controller.perform(.relaunch, on: info) }
            Button("結束") { controller.perform(.quit, on: info) }
            Button("強制結束…", role: .destructive) { controller.perform(.requestForceQuit, on: info) }
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.35))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var confirmForceQuit: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("強制結束「\(info.name)」？未儲存的資料會遺失")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Button("取消") { controller.perform(.cancelForceQuit, on: info) }
                .controlSize(.small)
            Button("強制結束") { controller.perform(.confirmForceQuit, on: info) }
                .controlSize(.small)
                .tint(.red)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Helpers

/// Pulsing red rim around the capsule while an app's CPU stays high.
struct HotGlow: View {
    let shape: NotchShape
    @State private var bright = false

    var body: some View {
        shape
            .stroke(Color.red.opacity(bright ? 0.95 : 0.35), lineWidth: 1.5)
            .shadow(color: .red.opacity(bright ? 0.8 : 0.2), radius: bright ? 6 : 2)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

struct PinFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
