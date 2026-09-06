import AppKit
import SwiftUI

extension UsageAlertLevel {
    /// The one place the three bands get their colors. Both UI layers read it,
    /// so the Touch Bar can never disagree with the popover about what a
    /// number means. `.normal` stays on the control accent color, so a window
    /// with nothing to say about it looks like the rest of the system rather
    /// than like a third verdict.
    var nsColor: NSColor {
        switch self {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Localization key for the band's name, used by the settings sliders.
    var nameKey: String {
        switch self {
        case .normal: return "alert_normal"
        case .warning: return "alert_warning"
        case .critical: return "alert_critical"
        }
    }
}

/// A usage bar: rounded track, colored fill, and — when the window's length is
/// known — a hairline at the point an even burn would have reached by now.
/// Being visibly past that mark is the "you are ahead of pace" signal every
/// comparable app draws, and it costs no extra row of text.
struct UsageBar: View {
    let percent: Int
    let paceMarkerPercent: Int?
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = max(0, min(1, Double(percent) / 100))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))

                Capsule(style: .continuous)
                    .fill(color.gradient)
                    .frame(width: fraction > 0 ? max(height, width * fraction) : 0)
            }
            .frame(width: width, height: height)
            // The mark stands a little proud of the track on both sides, which
            // is what makes it readable at this size. It has to be an overlay
            // rather than another layer of the stack above: inside the stack
            // its extra height set the stack's height, and the capsules filled
            // that — so a bar with a pace mark drew 8pt tall and one without
            // drew 6pt, side by side in the same list.
            .overlay(alignment: .leading) {
                if let paceMarkerPercent {
                    let position = max(0, min(1, Double(paceMarkerPercent) / 100))
                    RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: height + 3)
                        .offset(x: (width - 1.5) * position)
                }
            }
        }
        .frame(height: height)
    }
}

/// Small pill used for plan names and per-model limits.
struct UsageChipBackground: ViewModifier {
    var tint: Color = .secondary

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }
}

extension View {
    func usageChip(tint: Color = .secondary) -> some View {
        modifier(UsageChipBackground(tint: tint))
    }
}
