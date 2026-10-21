import SwiftUI

struct AircraftCard: View {
    let aircraft: Aircraft
    let isExpanded: Bool
    /// Picked on the radar or by a tap: drawn with an outline.
    var isSelected = false
    let toggle: () -> Void
    @State private var aircraftInfo: AircraftDetails?

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
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
            )
            .shadow(color: Theme.accent.opacity(isSelected ? 0.3 : 0), radius: 12)
            .animation(.snappy, value: isSelected)
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
        }
    }

    /// Airborne: how high it is. On the ground: its state.
    @ViewBuilder
    private var trailing: some View {
        if aircraft.onGround {
            Chip(text: aircraft.isMoving ? String(localized: "Taxiing") : String(localized: "Stopped"),
                 tint: aircraft.isMoving ? Theme.warning : Theme.positive)
        } else if let altitude = aircraft.heightFt {
            // The same type sizes as the two lines on the left, so each line sits level with its neighbour.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if aircraft.isVeryLow {
                        Text("Low").font(.headline)
                    } else {
                        Text(altitude.formatted(.number))
                            .font(.headline)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("ft")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let phase = aircraft.flightPhase {
                    Label(phase.label, systemImage: phase.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("altitude")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.smooth, value: altitude)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(altitude: altitude))
        }
    }

    private func accessibilityText(altitude: Int) -> Text {
        let height = aircraft.isVeryLow ? String(localized: "Flying low") : String(localized: "Altitude \(Format.altitude(altitude))")
        guard let phase = aircraft.flightPhase else { return Text(height) }
        return Text("\(phase.label). \(height)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.top, 14)
            if aircraft.hasRoute {
                RouteView(fromCode: aircraft.originCode, fromCity: Aircraft.city(from: aircraft.origin),
                          toCode: aircraft.destinationCode, toCity: Aircraft.city(from: aircraft.destination))
            }
            if let schedule = aircraft.schedule {
                ScheduleTimes(schedule: schedule)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], spacing: 14) {
                ForEach(facts, id: \.title) { fact in
                    FactView(fact: fact)
                }
            }
        }
        .loadsAircraftDetails(for: aircraft.registration, into: $aircraftInfo)
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let type = aircraft.type {
            facts.append(Fact(symbol: "airplane", title: String(localized: "Aircraft"), value: type))
        }
        if let registration = aircraft.registration {
            facts.append(Fact(symbol: "number", title: String(localized: "Registration"), value: registration))
            if let age = aircraftInfo?.ageFact { facts.append(age) }
        }
        if aircraft.onGround {
            facts.append(Fact(symbol: "speedometer", title: String(localized: "Speed"),
                              value: aircraft.speedKt.map { "\($0) kt" } ?? String(localized: "Stopped")))
        } else {
            if let altitude = aircraft.heightFt {
                facts.append(Fact(symbol: "arrow.up.to.line", title: String(localized: "Altitude"),
                                  value: aircraft.isVeryLow ? String(localized: "Below 100 ft") : Format.altitude(altitude),
                                  detail: aircraft.isVeryLow ? nil : Format.meters(fromFeet: altitude)))
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
        facts.append(Fact(symbol: "location.north.line", title: aircraft.onGround || aircraft.elevationDeg == nil ? String(localized: "From you") : String(localized: "Where to look"),
                          value: "\(aircraft.compass) · \(Format.distance(aircraft.distanceM))",
                          detail: aircraft.elevationDeg.map { "\(aircraft.skyPosition ?? "") · \($0)°" }))
        return facts
    }
}

struct Fact {
    let symbol: String
    let title: String
    let value: String
    var detail: String?
}

struct FactView: View {
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

/// Where the flight started and where it is going: two codes with their cities and a dashed line between.
struct RouteView: View {
    let fromCode: String?
    let fromCity: String?
    let toCode: String?
    let toCity: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            end(code: fromCode, place: fromCity, alignment: .leading)
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
            end(code: toCode, place: toCity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route")
        .accessibilityValue("\(fromCity ?? fromCode ?? "unknown") to \(toCity ?? toCode ?? "unknown")")
    }

    private func end(code: String?, place: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code ?? "—")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Text(place ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 70, alignment: alignment == .leading ? .leading : .trailing)
    }
}
