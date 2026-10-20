import SwiftUI

/// A compass radar: you in the middle, the aircraft as dots at their direction and distance. With a compass reading
/// the dial turns with the phone, so N, E, S and W sit in their real directions and an aircraft straight ahead is at
/// the top. Without one, north is at the top.
struct RadarView: View {
    let aircraft: [Aircraft]
    let radiusMeters: Int
    /// When the aircraft were reported. Dots drift along their track from then, until the next refresh.
    let updatedAt: Date?
    let heading: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    /// Reduce Motion, or Low Power Mode: the sweep and the drift are decoration, so they stop.
    private var reduceMotion: Bool { reduceMotionSetting || ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Compass letters on the rim, as a direction from the centre (x to the right, y downwards).
    private static let directions: [(letter: String, x: CGFloat, y: CGFloat)] = [
        ("N", 0, -1), ("E", 1, 0), ("S", 0, 1), ("W", -1, 0),
    ]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let facing = heading ?? 0
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.07))
                    dial(side: side, radius: radius, facing: facing)
                    if !reduceMotion {
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                        Circle()
                            .fill(AngularGradient(colors: [.clear, Theme.accent.opacity(0.32)], center: .center))
                            .rotationEffect(.degrees(turn * 360))
                            .mask(Circle())
                            .allowsHitTesting(false)
                    }
                    if heading != nil {
                        ViewCone()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                                 startPoint: .center, endPoint: .top))
                            .frame(width: side, height: side)
                            .transition(.opacity)
                    }
                    ForEach(aircraft) { item in
                        dot(for: item, now: context.date, radius: radius, facing: facing)
                    }
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                }
                .frame(width: side, height: side)
            }
            .animation(.smooth(duration: 0.25), value: heading)
            .animation(.smooth(duration: 0.8), value: aircraft)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(heading == nil ? "Radar, north at the top" : "Compass radar, the top is where you face")
        .accessibilityValue("\(aircraft.count) aircraft within \(Format.distance(radiusMeters))")
    }

    /// The rings, cross-hair and letters. They turn against the phone, and each letter turns back to stay upright.
    private func dial(side: CGFloat, radius: CGFloat, facing: Double) -> some View {
        ZStack {
            ForEach([1.0 / 3, 2.0 / 3, 1.0], id: \.self) { fraction in
                Circle()
                    .strokeBorder(Theme.accent.opacity(fraction == 1 ? 0.45 : 0.2), lineWidth: 1)
                    .frame(width: side * fraction, height: side * fraction)
            }
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(width: 1)
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(height: 1)
            ForEach(Self.directions, id: \.letter) { direction in
                Text(direction.letter)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(direction.letter == "N" ? Theme.warning : Theme.accent.opacity(0.75))
                    .rotationEffect(.degrees(facing))
                    .offset(x: direction.x * (radius - 12), y: direction.y * (radius - 12))
            }
        }
        .rotationEffect(.degrees(-facing))
    }

    private func dot(for item: Aircraft, now: Date, radius: CGFloat, facing: Double) -> some View {
        let spot = item.projected(after: updatedAt.map { now.timeIntervalSince($0) } ?? 0)
        let angle = Compass.relative(bearing: spot.bearing, heading: facing) * .pi / 180
        let reach = min(1, spot.distance / Double(max(radiusMeters, 1))) * Double(radius - 6)
        return Circle()
            .fill(Theme.warning)
            .frame(width: 9, height: 9)
            .shadow(color: Theme.warning.opacity(0.7), radius: 4)
            .offset(x: sin(angle) * reach, y: -cos(angle) * reach)
            .transition(.scale.combined(with: .opacity))
    }
}

/// A wedge pointing up from the centre: the way you are facing.
nonisolated struct ViewCone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2 - 2,
                    startAngle: .degrees(-90 - 22), endAngle: .degrees(-90 + 22), clockwise: false)
        path.closeSubpath()
        return path
    }
}
