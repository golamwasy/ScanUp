import SwiftUI

struct AircraftCard: View {
    let aircraft: Aircraft
    var heading: Double?
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 0) {
                header
                if isExpanded {
                    details
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(14)
            .cardBackground()
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .sensoryFeedback(.selection, trigger: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
    }

    private var header: some View {
        HStack(spacing: 14) {
            AirlineBadge(aircraft: aircraft)
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !aircraft.subtitle.isEmpty {
                    Text(aircraft.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            trailing.fixedSize()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if aircraft.onGround {
                Chip(text: aircraft.isMoving ? String(localized: "Taxiing") : String(localized: "Stopped"),
                     tint: aircraft.isMoving ? Theme.warning : Theme.positive)
            } else {
                Text(Format.distance(aircraft.distanceM))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(Compass.relative(bearing: Double(aircraft.bearingDeg), heading: heading)))
                        .animation(.smooth(duration: 0.25), value: heading)
                    Text(aircraft.lookDirection)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
            }
        }
        .animation(.smooth, value: aircraft.distanceM)
        .animation(.smooth, value: aircraft.bearingDeg)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.top, 14)
            if aircraft.hasRoute {
                RouteRow(aircraft: aircraft)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], spacing: 14) {
                ForEach(facts, id: \.title) { fact in
                    FactView(fact: fact)
                }
            }
        }
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let type = aircraft.type {
            facts.append(Fact(symbol: "airplane", title: String(localized: "Aircraft"), value: type))
        }
        if let registration = aircraft.registration {
            facts.append(Fact(symbol: "number", title: String(localized: "Registration"), value: registration))
        }
        if aircraft.onGround {
            facts.append(Fact(symbol: "speedometer", title: String(localized: "Speed"),
                              value: aircraft.speedKt.map { "\($0) kt" } ?? String(localized: "Stopped")))
        } else {
            if let altitude = aircraft.altitudeFt {
                facts.append(Fact(symbol: "arrow.up.to.line", title: String(localized: "Altitude"),
                                  value: Format.altitude(altitude), detail: Format.meters(fromFeet: altitude)))
            }
            if let speed = aircraft.speedKt {
                facts.append(Fact(symbol: "speedometer", title: String(localized: "Speed"), value: "\(speed) kt",
                                  detail: "\(Int((Double(speed) * 1.852).rounded())) km/h"))
            }
            if let heading = aircraft.headingDeg {
                facts.append(Fact(symbol: "safari", title: String(localized: "Heading"),
                                  value: "\(heading)° \(Aircraft.compassPoint(for: heading))"))
            }
            if let trend = aircraft.trend {
                let rate = aircraft.verticalRateFpm.map { abs($0).formatted(.number) + " ft/min" }
                facts.append(Fact(symbol: trend.symbol, title: String(localized: "Vertical"),
                                  value: trend.label, detail: trend == .level ? nil : rate))
            }
        }
        facts.append(Fact(symbol: "location.north.line", title: aircraft.onGround ? String(localized: "From you") : String(localized: "Where to look"),
                          value: "\(aircraft.compass) · \(Format.distance(aircraft.distanceM))",
                          detail: aircraft.elevationDeg.map { "\(aircraft.skyPosition ?? "") · \($0)°" }))
        return facts
    }
}

private struct Fact {
    let symbol: String
    let title: String
    let value: String
    var detail: String?
}

private struct FactView: View {
    let fact: Fact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.symbol)
                .font(.callout)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fact.value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let detail = fact.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Where the flight started and where it is going.
private struct RouteRow: View {
    let aircraft: Aircraft

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            end(code: aircraft.originCode, place: aircraft.origin, alignment: .leading)
            HStack(spacing: 6) {
                DashedLine().stroke(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .frame(height: 2)
                Image(systemName: "airplane")
                    .foregroundStyle(Theme.accent)
                DashedLine().stroke(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            end(code: aircraft.destinationCode, place: aircraft.destination, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route")
        .accessibilityValue("\(aircraft.origin ?? "unknown") to \(aircraft.destination ?? "unknown")")
    }

    private func end(code: String?, place: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code ?? "—")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Text(Aircraft.city(from: place) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 70, alignment: alignment == .leading ? .leading : .trailing)
    }
}
