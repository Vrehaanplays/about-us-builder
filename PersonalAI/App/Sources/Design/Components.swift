import SwiftUI

/// The app's feel: every button sits on a solid 6pt lip and presses down onto it in 70ms, springing back on release.
struct LipButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, danger, lime }
    var kind: Kind = .primary
    var fullWidth = true
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let lip: CGFloat = 6
        let pressed = configuration.isPressed
        let (bg, fg, lipColor, stroke): (Color, Color, Color, Bool) = {
            switch kind {
            case .primary: return (p.ctaBg, p.ctaFg, p.ctaLip, false)
            case .lime: return (PB.lime, PB.ink, Color(hex: 0x8BAA1C), false)
            case .danger: return (PB.coral, PB.ink, Color(hex: 0xB93A17), false)
            case .outline: return (.clear, p.fg, p.fg.opacity(0.0), true)
            }
        }()
        configuration.label
            .font(PBFont.heavy(18, relativeTo: .body))
            .foregroundStyle(fg)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 58)
            .padding(.horizontal, fullWidth ? 0 : 24)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(p.fg, lineWidth: stroke ? 2.5 : 0))
            .background(Capsule().fill(lipColor).offset(y: stroke ? 0 : lip))
            .offset(y: pressed && !stroke ? lip : 0)
            .animation(reduce ? nil : .easeOut(duration: 0.07), value: pressed)
            .padding(.bottom, stroke ? 0 : lip)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct Sticker: View {
    let text: String
    var tilt: Double = -5
    var fill: Color = PB.lime
    var body: some View {
        Text(text.uppercased())
            .font(PBFont.label)
            .tracking(0.4)
            .foregroundStyle(fill == PB.violet || fill == PB.ink ? Color.white : PB.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .rotationEffect(.degrees(tilt))
            .accessibilityLabel(text)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var emphasised = false
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 6) {
            if let s = systemImage { Image(systemName: s).font(.system(size: 12, weight: .bold)) }
            Text(text).font(PBFont.meta)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(emphasised ? PB.ink : p.fg)
        .background(Capsule().fill(emphasised ? PB.lime : p.fg.opacity(0.08)))
    }
}

/// States the user must never mistake: where did this computation happen?
struct LocalityBadge: View {
    enum Where { case onDevice, imported, cloud }
    let where_: Where
    var body: some View {
        switch where_ {
        case .onDevice: Sticker(text: "On this iPhone", tilt: -3, fill: PB.lime)
        case .imported: Sticker(text: "Imported", tilt: 2, fill: PB.violet)
        case .cloud: Sticker(text: "Cloud", tilt: -3, fill: PB.coral)
        }
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.palette) private var p
    func body(content: Content) -> some View {
        content.padding(18).background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(p.card))
    }
}
extension View { func card() -> some View { modifier(CardBackground()) } }

struct ScreenHeader: View {
    let title: String
    var subtitle: String?
    @Environment(\.palette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(PBFont.title).tracking(-1.4).lineLimit(2).minimumScaleFactor(0.7)
            if let s = subtitle { Text(s).font(PBFont.body).foregroundStyle(p.sub) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    let title: String, message: String
    var systemImage = "tray"
    var action: (title: String, run: () -> Void)?
    @Environment(\.palette) private var p
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .bold)).foregroundStyle(p.accent)
            Text(title).font(PBFont.section).multilineTextAlignment(.center)
            Text(message).font(PBFont.body).foregroundStyle(p.sub).multilineTextAlignment(.center)
            if let a = action { Button(a.title, action: a.run).buttonStyle(LipButtonStyle(kind: .primary, fullWidth: false)).padding(.top, 6) }
        }
        .padding(PB.margin).frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PB.ink)
            Text(message).font(PBFont.meta).foregroundStyle(PB.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let r = retry { Button("Retry", action: r).font(PBFont.label).foregroundStyle(PB.ink).underline() }
            if let d = dismiss { Button { d() } label: { Image(systemName: "xmark") }.foregroundStyle(PB.ink).accessibilityLabel("Dismiss") }
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PB.coral))
        .accessibilityElement(children: .combine)
    }
}

/// A row of short bars: progress through a multi-step flow, or the fill of a budget.
struct SegmentBar: View {
    let fraction: Double
    var segments = 12
    var tint: Color = PB.lime
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3).fill(Double(i) < fraction * Double(segments) ? tint : p.fg.opacity(0.12)).frame(height: 8)
            }
        }
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
