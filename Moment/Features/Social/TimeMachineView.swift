import SwiftUI

/// "3 years ago today…" — Moments from this date in earlier years. Share them, relive them.
struct TimeMachineView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showCardFor: SocialMoment?
    var body: some View {
        let buckets = env.social.timeMachine
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TIME MACHINE").font(MFont.eyebrow).tracking(1.5).foregroundStyle(MColor.accent)
                    Text(Date.now.formatted(.dateTime.month(.wide).day())).displayStyle()
                    Text("What happened on this day, in other years.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                if buckets.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Nothing from this day yet.").font(MFont.title)
                        Text("Come back next year — today's Moments will be waiting here.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                    }
                    .momentCard()
                }
                ForEach(buckets, id: \.yearsAgo) { bucket in
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("\(bucket.yearsAgo == 1 ? "ONE YEAR" : "\(bucket.yearsAgo) YEARS") AGO").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                        ForEach(bucket.moments) { m in
                            NavigationLink(value: SocialRoute.moment(m.id)) { MomentFeedCard(moment: m, reason: "with \(m.memberNames.filter { $0 != env.social.displayName }.prefix(2).joined(separator: ", "))") }.buttonStyle(PressScaleStyle())
                            Button { showCardFor = m } label: { Label("Share this memory", systemImage: "square.and.arrow.up") }.buttonStyle(ChipButtonStyle())
                        }
                    }
                }
            }
            .padding(MSpacing.l).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $showCardFor) { MomentCardSheet(moment: $0) }
        .accessibilityIdentifier("timeMachine")
    }
}

/// Home card: the strongest Time Machine hit for today.
struct TimeMachineCard: View {
    @Environment(AppEnvironment.self) private var env
    let yearsAgo: Int
    let moment: SocialMoment
    @State private var tint: Color = MColor.accent
    var body: some View {
        NavigationLink(value: SocialRoute.timeMachine) {
            HStack(spacing: MSpacing.m) {
                SocialImage(ref: moment.coverRef).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(yearsAgo == 1 ? "ONE YEAR" : "\(yearsAgo) YEARS") AGO TODAY").font(MFont.eyebrow).tracking(1).foregroundStyle(tint)
                    Text(moment.title).font(MFont.heroSmall).foregroundStyle(MColor.textPrimary).lineLimit(1)
                    Text("with \(moment.memberNames.filter { $0 != env.social.displayName }.prefix(2).joined(separator: ", "))").font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(tint)
            }
            .momentCard()
            .overlay(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .task { tint = await env.social.tint(for: moment) }
        .accessibilityIdentifier("onThisDay")
    }
}
