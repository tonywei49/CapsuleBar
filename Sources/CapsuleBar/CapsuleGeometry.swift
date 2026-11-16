import AppKit

/// Where the capsule sits on one screen.
struct CapsuleGeometry {
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchWidth: CGFloat     // 0 on screens without a notch
    let barHeight: CGFloat      // notch height, or menu bar height

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            barHeight = screen.safeAreaInsets.top
        } else {
            hasNotch = false
            notchWidth = 0
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            barHeight = menuBar > 0 ? menuBar : 24
        }
    }

    static let gaugeWidth: CGFloat = 38
    static let pinWidth: CGFloat = 20

    /// Width of each "wing" beside the notch: CPU gauge (+ pins) on the left, memory gauge on
    /// the right. Both sides match so the capsule stays centered on the notch.
    func wingWidth(pinCount: Int) -> CGFloat {
        let left = CGFloat(pinCount) * Self.pinWidth + Self.gaugeWidth + 16
        let right = Self.gaugeWidth + 16
        return max(left, right)
    }

    func collapsedSize(pinCount: Int) -> CGSize {
        let middle = hasNotch ? notchWidth : 8
        return CGSize(width: middle + wingWidth(pinCount: pinCount) * 2, height: barHeight)
    }

    func expandedSize(pinCount: Int) -> CGSize {
        let width = max(collapsedSize(pinCount: pinCount).width, 480)
        let height = min(560, screenFrame.height * 0.75)
        return CGSize(width: width, height: height)
    }

    /// Window frame for a size, top-centered on the screen (overlapping the menu bar).
    func frame(for size: CGSize) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2,
               y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}
