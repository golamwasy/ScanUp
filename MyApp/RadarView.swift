import SwiftUI

/// A compass radar: you in the middle, the aircraft as small planes at their direction and distance, pointing the way
/// they fly. With a compass reading the dial turns with the phone, so N, E, S and W sit in their real directions and an
/// aircraft straight ahead is at the top. Without one, north is at the top.
struct RadarView: View {
    let aircraft: [Aircraft]
    let radiusMeters: Int
    /// When the aircraft were reported. Planes drift along their track from then, until the next refresh.
    let updatedAt: Date?
    let heading: Double?
    /// The aircraft picked by a tap, on the radar or in the list. Its plane is drawn larger, inside a ring.
    var selectedID: String?
    var onSelect: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    /// Reduce Motion, or Low Power Mode: the sweep, the ping and the drift are decoration, so they stop.
    private var reduceMotion: Bool { reduceMotionSetting || ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Compass letters on the rim, as a direction from the centre (x to the right, y downwards).
    private static let directions: [(letter: String, x: CGFloat, y: CGFloat)] = [
        ("N", 0, -1), ("E", 1, 0), ("S", 0, 1), ("W", -1, 0),
    ]
    private static let rings: [Double] = [1.0 / 3, 2.0 / 3, 1.0]
    /// How long the ring that spreads from you after each refresh takes to fade.
    private static let pingDuration: TimeInterval = 1.4

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let facing = heading ?? 0
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                ZStack {
                    Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.05)],
                                                 center: .center, startRadius: 0, endRadius: radius))
                    dial(side: side, radius: radius, facing: facing)
                    if !reduceMotion {
                        sweep(at: context.date, radius: radius)
                        ping(at: context.date, side: side)
                    }
                    if heading != nil {
                        ViewCone()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                                 startPoint: .center, endPoint: .top))
                            .frame(width: side, height: side)
                            .transition(.opacity)
                    }
                    ForEach(aircraft) { item in
                        plane(for: item, now: context.date, radius: radius, facing: facing)
                    }
                    you(at: context.date)
                }
                .frame(width: side, height: side)
            }
            .animation(.smooth(duration: 0.25), value: heading)
            .animation(.smooth(duration: 0.8), value: aircraft)
            .animation(.snappy, value: selectedID)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(heading == nil ? "Radar, north at the top" : "Compass radar, the top is where you face")
        .accessibilityValue("\(aircraft.count) aircraft within \(Format.distance(radiusMeters))")
    }

    /// The rim with its tick marks, the rings, the cross-hair and the letters. They turn against the phone, and each
    /// letter turns back to stay upright.
    private func dial(side: CGFloat, radius: CGFloat, facing: Double) -> some View {
        ZStack {
            ForEach(Self.rings, id: \.self) { fraction in
                Circle()
                    .strokeBorder(Theme.accent.opacity(fraction == 1 ? 0.5 : 0.2), lineWidth: fraction == 1 ? 1.5 : 1)
                    .frame(width: side * fraction, height: side * fraction)
            }
            BezelTicks()
                .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
                .frame(width: side - 6, height: side - 6)
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(width: 1)
            Rectangle().fill(Theme.accent.opacity(0.15)).frame(height: 1)
            ForEach(Self.directions, id: \.letter) { direction in
                Text(direction.letter)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(direction.letter == "N" ? Theme.warning : Theme.accent)
                    .rotationEffect(.degrees(facing))
                    .offset(x: direction.x * (radius - 20), y: direction.y * (radius - 20))
            }
        }
        .rotationEffect(.degrees(-facing))
    }

    /// The beam that goes round every four seconds, with a fading trail behind it.
    private func sweep(at date: Date, radius: CGFloat) -> some View {
        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
        return ZStack {
            Circle().fill(AngularGradient(stops: [.init(color: .clear, location: 0),
                                                  .init(color: .clear, location: 0.7),
                                                  .init(color: Theme.accent.opacity(0.4), location: 1)],
                                          center: .center))
            Rectangle().fill(Theme.accent.opacity(0.55))
                .frame(width: radius, height: 1.5)
                .offset(x: radius / 2)
        }
        .rotationEffect(.degrees(turn * 360))
        .mask(Circle())
        .allowsHitTesting(false)
    }

    /// A ring that spreads from you each time new aircraft arrive.
    @ViewBuilder
    private func ping(at date: Date, side: CGFloat) -> some View {
        if let updatedAt, case let age = date.timeIntervalSince(updatedAt), age >= 0, age < Self.pingDuration {
            let progress = age / Self.pingDuration
            Circle()
                .stroke(Theme.accent.opacity((1 - progress) * 0.7), lineWidth: 2)
                .frame(width: side * progress, height: side * progress)
                .allowsHitTesting(false)
        }
    }

    /// You, with a halo that breathes.
    private func you(at date: Date) -> some View {
        let breath = reduceMotion ? 0.5 : (sin(date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
        return ZStack {
            Circle().fill(Theme.accent.opacity(0.28 - 0.14 * breath)).frame(width: 18 + 12 * breath, height: 18 + 12 * breath)
            Circle().fill(Theme.accent).frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 2))
        }
    }

    /// An aircraft: a small plane pointing along its track, or a dot when the track is unknown. A tap picks it.
    private func plane(for item: Aircraft, now: Date, radius: CGFloat, facing: Double) -> some View {
        let spot = item.projected(after: updatedAt.map { now.timeIntervalSince($0) } ?? 0)
        let angle = Compass.relative(bearing: spot.bearing, heading: facing) * .pi / 180
        let reach = min(1, spot.distance / Double(max(radiusMeters, 1))) * Double(radius - 14)
        let isSelected = item.id == selectedID
        return ZStack {
            if isSelected {
                Circle().fill(Theme.warning.opacity(0.2))
                    .overlay(Circle().strokeBorder(Theme.warning, lineWidth: 1.5))
                    .frame(width: 32, height: 32)
                    .transition(.scale.combined(with: .opacity))
            }
            Group {
                if let track = item.headingDeg {
                    // The symbol points right, so it turns a quarter back to point at the top for a track of north.
                    Image(systemName: "airplane")
                        .font(.system(size: 15, weight: .bold))
                        .rotationEffect(.degrees(Double(track) - facing - 90))
                } else {
                    Circle().frame(width: 9, height: 9)
                }
            }
            .foregroundStyle(Theme.warning)
            .shadow(color: Theme.warning.opacity(0.7), radius: 4)
            .scaleEffect(isSelected ? 1.25 : 1)
        }
        // A finger needs more room than a 15 point plane.
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .onTapGesture { onSelect(item.id) }
        .offset(x: sin(angle) * reach, y: -cos(angle) * reach)
        .transition(.scale.combined(with: .opacity))
    }
}

/// Short marks round the rim every 10 degrees, longer ones every 30.
nonisolated struct BezelTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for step in 0..<36 {
            let angle = Double(step) * 10 * .pi / 180
            let length: CGFloat = step % 3 == 0 ? 7 : 3.5
            path.move(to: CGPoint(x: center.x + sin(angle) * (outer - length), y: center.y - cos(angle) * (outer - length)))
            path.addLine(to: CGPoint(x: center.x + sin(angle) * outer, y: center.y - cos(angle) * outer))
        }
        return path
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
