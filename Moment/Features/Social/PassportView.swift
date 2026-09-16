import SwiftUI

/// Your Moment Passport: places, people, trips, nights — stamped from real Moments. Nothing invented.
struct PassportView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let p = env.social.passport
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MOMENT PASSPORT").font(MFont.eyebrow).tracking(2).foregroundStyle(MColor.accent)
                    Text(env.social.displayName).displayStyle()
                    Text(p.years.isEmpty ? "No stamps yet." : "Since \(p.years.last.map(String.init) ?? "")").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: MSpacing.s), GridItem(.flexible(), spacing: MSpacing.s)], spacing: MSpacing.s) {
                    StatTile(value: "\(p.places.count)", label: "places", symbol: "mappin.and.ellipse")
                    StatTile(value: "\(p.people)", label: "people", symbol: "person.2")
                    StatTile(value: "\(p.trips)", label: "trips", symbol: "airplane")
                    StatTile(value: "\(p.nights)", label: "nights out", symbol: "moon.stars")
                    StatTile(value: "\(p.events)", label: "big events (5+)", symbol: "party.popper")
                    StatTile(value: "\(env.social.momentsImIn.count)", label: "Moments", symbol: "rectangle.stack")
                }
                if !p.places.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("STAMPS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                        FlowChips {
                            ForEach(p.places, id: \.name) { place in
                                VStack(spacing: 2) {
                                    Text(place.name.uppercased()).font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1)
                                    Text("×\(place.count)").font(.caption2).foregroundStyle(MColor.textSecondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MColor.accent.opacity(0.6), lineWidth: 1.5))
                                .rotationEffect(.degrees(Double((place.name.hashValue % 7) - 3)))
                                .foregroundStyle(MColor.accent)
                            }
                        }
                    }
                }
                NavigationLink(value: SocialRoute.map) { Label("Open the map", systemImage: "map").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle())
                if env.social.yearSummary() != nil { NavigationLink(value: SocialRoute.timeMachine) { Label("Time Machine", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle()) }
                Text("The passport is built from your own Moments on this device. It's private unless you share a card.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("passport")
    }
}
