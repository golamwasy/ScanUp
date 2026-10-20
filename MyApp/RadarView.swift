import SwiftUI

/// A small radar with you in the middle and an aircraft as a dot at its direction and distance.
struct RadarView: View {
    let aircraft: [Aircraft]
    let radiusMeters: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Compass letters on the rim, as a direction from the centre (x to the right, y downwards).
    private static let directions: [(letter: String, x: CGFloat, y: CGFloat)] = [
        ("N", 0, -1), ("E", 1, 0), ("S", 0, 1), ("W", -1, 0),
    ]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            ZStack {
                Circle().fill(Theme.accent.opacity(0.07))
                ForEach([1.0 / 3, 2.0 / 3, 1.0], id: \.self) { fraction in
                    Circle()
                        .strokeBorder(Theme.accent.opacity(fraction == 1 ? 0.45 : 0.2), lineWidth: 1)
                        .frame(width: side * fraction, height: side * fraction)
                }
                Rectangle().fill(Theme.accent.opacity(0.15)).frame(width: 1)
                Rectangle().fill(Theme.accent.opacity(0.15)).frame(height: 1)

                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                        Circle()
                            .fill(AngularGradient(colors: [.clear, Theme.accent.opacity(0.32)], center: .center))
                            .rotationEffect(.degrees(turn * 360))
                    }
                    .mask(Circle())
                    .allowsHitTesting(false)
                }

                ForEach(aircraft) { item in
                    let angle = Double(item.bearingDeg) * .pi / 180
                    let distance = min(1, Double(item.distanceM) / Double(max(radiusMeters, 1)))
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 9, height: 9)
                        .shadow(color: Theme.warning.opacity(0.7), radius: 4)
                        .offset(x: sin(angle) * distance * (radius - 6), y: -cos(angle) * distance * (radius - 6))
                        .transition(.scale.combined(with: .opacity))
                }
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                ForEach(Self.directions, id: \.letter) { direction in
                    Text(direction.letter)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent.opacity(direction.letter == "N" ? 0.95 : 0.7))
                        .offset(x: direction.x * (radius - 12), y: direction.y * (radius - 12))
                }
            }
            .frame(width: side, height: side)
            .animation(.smooth(duration: 0.8), value: aircraft)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Radar")
        .accessibilityValue("\(aircraft.count) aircraft within \(Format.distance(radiusMeters))")
    }
}
