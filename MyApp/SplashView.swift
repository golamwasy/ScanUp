import SwiftUI

/// The intro shown once when the app starts: the icon's radar drawn in motion. Rings spread out, a plane rises through
/// them, an orange dot flies a lap round the outer ring, and the name settles in. It always uses the dark night
/// colours of the icon, in light mode as well, and it starts on the same graphite as the system's launch screen so there
/// is no flash between them.
struct SplashView: View {
    /// Called when the intro has played and the app can fade in.
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringsOut = false
    @State private var planeUp = false
    @State private var wordIn = false
    @State private var sweep = 0.0
    @State private var orbit = 0.0

    private static let night = Color(red: 0.055, green: 0.055, blue: 0.06)
    /// The thin white of the icon's lines.
    private static let line = Color(red: 0.93, green: 0.94, blue: 0.95)
    private static let ember = Color(red: 1.0, green: 0.62, blue: 0.15)
    private static let markSize: CGFloat = 220
    /// Where the orange dot rests at the end, as in the icon: upper right.
    private static let restAngle = 40.0

    var body: some View {
        ZStack {
            Self.night
            RadialGradient(colors: [Color.white.opacity(ringsOut ? 0.06 : 0), .clear], center: .init(x: 0.5, y: 0.42),
                           startRadius: 0, endRadius: 420)
            VStack(spacing: 40) {
                mark.frame(width: Self.markSize, height: Self.markSize)
                wordmark
            }
            .offset(y: -20)
        }
        .ignoresSafeArea()
        .sensoryFeedback(.impact(weight: .light), trigger: planeUp)
        .accessibilityElement()
        .accessibilityLabel("ScanUp")
        .task { await play() }
    }

    private var mark: some View {
        ZStack {
            // Inner ring first, so the rings spread outwards one after the other.
            ForEach(0..<3, id: \.self) { index in
                let size = Self.markSize * [1.0, 0.7, 0.4][index]
                Circle()
                    .strokeBorder(Self.line.opacity([0.5, 0.28, 0.18][index]), lineWidth: index == 0 ? 1.4 : 1)
                    .frame(width: size, height: size)
                    .scaleEffect(ringsOut ? 1 : 0.4)
                    .opacity(ringsOut ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(Double(2 - index) * 0.08), value: ringsOut)
            }
            Circle()
                .fill(AngularGradient(stops: [.init(color: .clear, location: 0),
                                              .init(color: .clear, location: 0.6),
                                              .init(color: Self.line.opacity(0.22), location: 1)], center: .center))
                .frame(width: Self.markSize, height: Self.markSize)
                .rotationEffect(.degrees(sweep * 360 - 90))
                .opacity(ringsOut ? 1 - sweep : 0)
            ForEach(0..<4, id: \.self) { quarter in
                // The compass ticks of the outer ring, at north, east, south and west.
                Rectangle()
                    .fill(Self.line.opacity(0.6))
                    .frame(width: 1.4, height: 9)
                    .offset(y: -Self.markSize / 2 + 6)
                    .rotationEffect(.degrees(Double(quarter) * 90))
                    .opacity(ringsOut ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.2), value: ringsOut)
            }
            comet
            plane
        }
    }

    /// The orange dot with its tail, one lap round the outer ring that ends where the icon has it.
    private var comet: some View {
        ZStack {
            Circle()
                .trim(from: max(0, orbit - 0.28), to: orbit)
                .stroke(LinearGradient(colors: [Self.ember.opacity(0), Self.ember], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: Self.markSize, height: Self.markSize)
                .rotationEffect(.degrees(Self.restAngle - 90))
                .opacity(orbit > 0 ? 1 : 0)
            Circle()
                .fill(Self.ember)
                .frame(width: 13, height: 13)
                .shadow(color: Self.ember, radius: 8)
                .offset(y: -Self.markSize / 2)
                .rotationEffect(.degrees(Self.restAngle + orbit * 360))
                .opacity(orbit > 0 ? 1 : 0)
        }
    }

    private var plane: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Self.line.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 2, height: planeUp ? 44 : 0)
                .offset(y: 92)
            // Filled with the background so the rings do not show through, then the thin outline of the icon.
            LinePlane().fill(Self.night)
                .frame(width: 150, height: 150)
            LinePlane().stroke(Self.line, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 150, height: 150)
        }
        .scaleEffect(planeUp ? 1 : 0.8)
        .offset(y: planeUp ? 0 : 150)
        .opacity(planeUp ? 1 : 0)
    }

    private var wordmark: some View {
        VStack(spacing: 8) {
            Text("ScanUp")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("See what is flying above you")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Self.line.opacity(0.55))
        }
        .opacity(wordIn ? 1 : 0)
        .offset(y: wordIn ? 0 : 14)
        .blur(radius: wordIn ? 0 : 6)
    }

    private func play() async {
        if reduceMotion {
            ringsOut = true
            planeUp = true
            wordIn = true
            try? await Task.sleep(for: .seconds(0.7))
            onFinished()
            return
        }
        ringsOut = true
        withAnimation(.easeInOut(duration: 1.2)) { sweep = 1 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.spring(duration: 0.7, bounce: 0.25)) { planeUp = true }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.easeInOut(duration: 0.9)) { orbit = 1 }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.smooth(duration: 0.5)) { wordIn = true }
        try? await Task.sleep(for: .milliseconds(800))
        onFinished()
    }
}

/// The plane of the app icon, nose up, drawn as an outline: an airliner from above with swept wings. The shape is
/// two units tall and wide, scaled to fill the rectangle it is given.
nonisolated struct LinePlane: Shape {
    /// The right half, from the nose to the tail. The left half mirrors it.
    private static let half: [(x: Double, y: Double)] = [
        (0.0, -1.0), (0.022, -0.99), (0.040, -0.955), (0.054, -0.90), (0.064, -0.80), (0.068, -0.60), (0.068, -0.22),
        (0.97, 0.24), (0.995, 0.285), (0.985, 0.335), (0.068, 0.10),
        (0.064, 0.56), (0.075, 0.70), (0.34, 0.86), (0.355, 0.905), (0.335, 0.94), (0.062, 0.90),
        (0.040, 0.975), (0.0, 1.0),
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.midX + x * scale, y: rect.midY + y * scale)
        }
        var path = Path()
        path.move(to: point(0, -1))
        for step in Self.half.dropFirst() { path.addLine(to: point(step.x, step.y)) }
        for step in Self.half.dropFirst().dropLast().reversed() { path.addLine(to: point(-step.x, step.y)) }
        path.closeSubpath()
        return path
    }
}
