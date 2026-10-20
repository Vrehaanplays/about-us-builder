import SwiftUI

/// Visual language from the Playbook "Loud" system: one heavy grotesque, flat saturated scenes, lime/coral/violet accents,
/// buttons that sit on a solid lip, everything that moves springs. Dark mode is the black scene with lime as the accent.
enum PB {
    static let lime = Color(hex: 0xC6F432)
    static let coral = Color(hex: 0xFF5B2E)
    static let violet = Color(hex: 0x6E4CFF)
    static let cream = Color(hex: 0xF2EFE6)
    static let ink = Color(hex: 0x111111)

    // Playbook motion tokens (stiffness / damping)
    static let bouncy = Animation.interpolatingSpring(stiffness: 300, damping: 16)
    static let snappy = Animation.interpolatingSpring(stiffness: 520, damping: 32)
    static let gentle = Animation.interpolatingSpring(stiffness: 180, damping: 21)
    static let wobbly = Animation.interpolatingSpring(stiffness: 240, damping: 11)

    static let space: [CGFloat] = [4, 8, 12, 16, 24, 32, 40, 48]
    static let margin: CGFloat = 22
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum PBFont {
    static func heavy(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font { .custom("BricolageGrotesque-ExtraBold", size: size, relativeTo: style) }
    static func medium(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font { .custom("BricolageGrotesque-Medium", size: size, relativeTo: style) }
    static var mega: Font { heavy(64, relativeTo: .largeTitle) }
    static var title: Font { heavy(34, relativeTo: .largeTitle) }
    static var section: Font { heavy(22, relativeTo: .title2) }
    static var lead: Font { medium(19, relativeTo: .title3) }
    static var body: Font { medium(17, relativeTo: .body) }
    static var bodyHeavy: Font { heavy(17, relativeTo: .body) }
    static var meta: Font { medium(13, relativeTo: .footnote) }
    static var label: Font { heavy(12, relativeTo: .caption) }
}

/// Resolved colours for the current scheme so views never branch on `colorScheme` themselves.
struct Palette {
    var bg: Color, fg: Color, sub: Color, card: Color, line: Color
    var ctaBg: Color, ctaFg: Color, ctaLip: Color
    var accent: Color
    static func resolve(_ scheme: ColorScheme) -> Palette {
        if scheme == .dark {
            return Palette(bg: PB.ink, fg: PB.cream, sub: PB.cream.opacity(0.65), card: Color.white.opacity(0.08), line: Color.white.opacity(0.14),
                           ctaBg: PB.lime, ctaFg: PB.ink, ctaLip: Color(hex: 0x8BAA1C), accent: PB.lime)
        }
        return Palette(bg: PB.cream, fg: PB.ink, sub: PB.ink.opacity(0.65), card: Color.white, line: PB.ink.opacity(0.10),
                       ctaBg: PB.ink, ctaFg: PB.lime, ctaLip: Color(hex: 0x000000), accent: PB.violet)
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.resolve(.light) }
extension EnvironmentValues { var palette: Palette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } } }

struct ThemedRoot<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        let p = Palette.resolve(scheme)
        content.environment(\.palette, p).tint(p.accent).background(p.bg.ignoresSafeArea())
    }
}

extension View {
    /// Plays `animation` unless the user asked for reduced motion, in which case state changes are instant.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View { modifier(MotionModifier(animation: animation, value: value)) }
    func scene() -> some View { modifier(SceneModifier()) }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation; let value: V
    func body(content: Content) -> some View { content.animation(reduce ? nil : animation, value: value) }
}
private struct SceneModifier: ViewModifier {
    @Environment(\.palette) private var p
    func body(content: Content) -> some View { content.background(p.bg.ignoresSafeArea()).foregroundStyle(p.fg) }
}
