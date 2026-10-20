import SwiftUI

/// The intro shown once when the app starts: the icon's radar drawn in motion. Rings spread out, a plane rises through
/// them, an orange dot flies a lap round the outer ring, and the name settles in. It always uses the dark night
/// colours of the icon, in light mode as well, and it starts on the same navy as the system's launch screen so there
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

    private static let night = Color(red: 0.012, green: 0.04, blue: 0.17)
    private static let glow = Color(red: 0.10, green: 0.35, blue: 0.85)
    private static let sky = Color(red: 0.36, green: 0.76, blue: 1.0)
    private static let ember = Color(red: 1.0, green: 0.62, blue: 0.15)
    private static let markSize: CGFloat = 220
    /// Where the orange dot rests at the end, as in the icon: upper right.
    private static let restAngle = 40.0

    var body: some View {
        ZStack {
            Self.night
            RadialGradient(colors: [Self.glow.opacity(ringsOut ? 0.45 : 0), .clear], center: .init(x: 0.5, y: 0.42),
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
                    .strokeBorder(Self.sky.opacity(0.55 - 0.12 * Double(index)), lineWidth: index == 0 ? 2 : 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(ringsOut ? 1 : 0.4)
                    .opacity(ringsOut ? 1 : 0)
                    .animation(.easeOut(duration: 0.8).delay(Double(2 - index) * 0.12), value: ringsOut)
            }
            Circle()
                .fill(AngularGradient(stops: [.init(color: .clear, location: 0),
                                              .init(color: .clear, location: 0.6),
                                              .init(color: Self.sky.opacity(0.5), location: 1)], center: .center))
                .frame(width: Self.markSize, height: Self.markSize)
                .rotationEffect(.degrees(sweep * 360 - 90))
                .opacity(ringsOut ? 1 - sweep : 0)
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
                .fill(LinearGradient(colors: [Self.sky.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 7, height: planeUp ? 70 : 0)
                .offset(y: 78)
            Image(systemName: "airplane")
                .font(.system(size: 84))
                .rotationEffect(.degrees(-90))
                .foregroundStyle(.white)
                .shadow(color: Self.sky.opacity(0.8), radius: 14)
        }
        .scaleEffect(planeUp ? 1 : 0.7)
        .offset(y: planeUp ? -6 : 150)
        .opacity(planeUp ? 1 : 0)
    }

    private var wordmark: some View {
        VStack(spacing: 8) {
            Text("ScanUp")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("See what is flying above you")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Self.sky.opacity(0.85))
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
            orbit = 0
            try? await Task.sleep(for: .seconds(0.9))
            onFinished()
            return
        }
        ringsOut = true
        withAnimation(.easeInOut(duration: 1.7)) { sweep = 1 }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.spring(duration: 0.9, bounce: 0.25)) { planeUp = true }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeInOut(duration: 1.2)) { orbit = 1 }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.smooth(duration: 0.7)) { wordIn = true }
        try? await Task.sleep(for: .milliseconds(1100))
        onFinished()
    }
}
