import SwiftUI

extension Color {
    /// A colour that follows light and dark mode.
    init(light: Color, dark: Color) {
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        // SwiftUI calls this from its background renderer, not the main thread. Without `@Sendable` the closure
        // counts as main-actor code in this project, and the system stops the app when it runs anywhere else.
        self.init(UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

enum Theme {
    // Light mode is a pale sky. Dark mode is neutral graphite, so the blue of the radar and the buttons stands out.
    static let skyTop = Color(light: Color(red: 0.80, green: 0.90, blue: 1.0),
                              dark: Color(red: 0.055, green: 0.055, blue: 0.06))
    static let skyBottom = Color(light: Color(red: 0.96, green: 0.98, blue: 1.0),
                                 dark: Color(red: 0.105, green: 0.105, blue: 0.115))
    static let skyGlow = Color(light: Color(red: 0.45, green: 0.70, blue: 1.0).opacity(0.55),
                               dark: Color.white.opacity(0.07))
    static let accent = Color(light: Color(red: 0.0, green: 0.44, blue: 0.86),
                              dark: Color(red: 0.36, green: 0.76, blue: 1.0))
    static let card = Color(light: Color.white.opacity(0.88), dark: Color.white.opacity(0.07))
    static let cardBorder = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.10))
    static let warning = Color(light: Color(red: 0.80, green: 0.42, blue: 0.0),
                               dark: Color(red: 1.0, green: 0.70, blue: 0.30))
    static let positive = Color(light: Color(red: 0.05, green: 0.55, blue: 0.30),
                                dark: Color(red: 0.40, green: 0.85, blue: 0.55))

    static let cornerRadius: CGFloat = 22
    static let spring = Animation.spring(duration: 0.45, bounce: 0.22)
}

struct SkyBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.skyTop, Theme.skyBottom], startPoint: .top, endPoint: .bottom)
            // A soft glow behind the radar at the top.
            RadialGradient(colors: [Theme.skyGlow, .clear], center: .init(x: 0.5, y: 0.12),
                           startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The rounded card every list item and message sits on.
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

/// Round badge with the airline's initials. The colour comes from the airline, so it stays the same.
struct AirlineBadge: View {
    let aircraft: Aircraft
    var size: CGFloat = 46

    var body: some View {
        let hue = Double(aircraft.colorSeed % 360) / 360
        Text(aircraft.initials)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                             Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .accessibilityHidden(true)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Small dashed line used between the two ends of a route.
nonisolated struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
