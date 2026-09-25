import SwiftUI

/// The creator's rate card, inside the conversation.
///
/// This is where the money actually gets made on a platform like this: not on a storefront somebody has
/// to go looking for, but in the DM, at the moment a fan is already talking to you. So the prices live
/// here — a fan sees what this person charges for a photo, a call, their time, and can buy any of it
/// without leaving the thread; the creator sees the same card and can change a price in two taps.
///
/// It is the same `BookingOffer` list the storefront uses. One set of prices, shown where it matters.
struct CreatorShopBar: View {
    @Environment(AppEnvironment.self) private var env
    /// The other person in this conversation.
    let creatorID: String
    let creatorName: String
    var onBook: (BookingOffer) -> Void
    var onAsk: () -> Void
    var onEdit: (BookingOffer?) -> Void
    var onLockedPhoto: () -> Void

    @State private var expanded = true

    /// Whose card this is. When I open a chat with a fan, it's mine to edit; otherwise it's theirs to buy.
    private var isMine: Bool { creatorID != env.social.myID && env.social.isCreator && offersOfOther.isEmpty }
    /// Ordered the way someone shops: the cheap, instant thing first, then time, then the open-ended
    /// ask. Price order would put a ₹299 custom ahead of a ₹499 call, which reads as random.
    private static let order: [BookingOffer.Kind] = [.photo, .videoCall, .voiceCall, .meet, .custom]
    private func sorted(_ o: [BookingOffer]) -> [BookingOffer] {
        o.sorted { (Self.order.firstIndex(of: $0.kind) ?? 9, $0.priceMinor) < (Self.order.firstIndex(of: $1.kind) ?? 9, $1.priceMinor) }
    }
    private var offersOfOther: [BookingOffer] { sorted(env.social.offers(of: creatorID).filter(\.active)) }
    private var myOffers: [BookingOffer] { sorted(env.social.offers(of: env.social.myID).filter(\.active)) }
    private var plan: CreatorPlan? { env.social.plan(for: creatorID) }

    /// Shown only when there is something to show: their prices, or my own to sell with.
    private var hasSomething: Bool { !offersOfOther.isEmpty || plan != nil || env.social.isCreator }

    var body: some View {
        if hasSomething {
            VStack(spacing: 0) {
                header
                if expanded {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: MSpacing.s) {
                            if offersOfOther.isEmpty && env.social.isCreator {
                                // My chat with a fan: my own prices, tappable to change.
                                ForEach(myOffers) { o in chip(o, mine: true) }
                                addChip
                                lockedPhotoChip
                            } else {
                                if let plan, !env.social.isSubscribed(to: creatorID) { subscribeChip(plan) }
                                ForEach(offersOfOther) { o in chip(o, mine: false) }
                                askChip
                            }
                        }
                        .padding(.horizontal, MSpacing.page)
                        .padding(.bottom, MSpacing.s)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(.bar)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
            .accessibilityIdentifier("creatorShopBar")
        }
    }

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: MSymbol.shop).font(.caption.weight(.semibold))
                Text(offersOfOther.isEmpty && env.social.isCreator
                     ? "What you charge"
                     : "\(creatorName.split(separator: " ").first.map(String.init) ?? creatorName)'s prices")
                    .font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(MColor.textSecondary)
            .padding(.horizontal, MSpacing.page)
            .padding(.top, MSpacing.s)
            .padding(.bottom, expanded ? 6 : MSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shopBarToggle")
    }

    /// One thing for sale. The price is on the chip — a fan should never have to tap to find out.
    private func chip(_ o: BookingOffer, mine: Bool) -> some View {
        Button { mine ? onEdit(o) : onBook(o) } label: {
            HStack(spacing: 7) {
                Image(systemName: o.kind.symbol).font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.minutes > 0 ? "\(o.kind.label) · \(o.minutes)m" : o.kind.label)
                        .font(.caption.weight(.semibold))
                    Text(o.priceLabel()).font(.caption2).foregroundStyle(MColor.accent)
                }
                if mine { Image(systemName: "pencil").font(.caption2).foregroundStyle(MColor.textTertiary) }
            }
            .foregroundStyle(MColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassPill()
        .accessibilityIdentifier("shopOffer-\(o.id)")
        .accessibilityLabel("\(o.kind.label), \(o.priceLabel())")
    }

    private func subscribeChip(_ p: CreatorPlan) -> some View {
        NavigationLink(value: SocialRoute.storefront(creatorID)) {
            HStack(spacing: 7) {
                Image(systemName: MSymbol.subscription).font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Subscribe").font(.caption.weight(.semibold))
                    Text("\(p.priceLabel()) / 30 days").font(.caption2).opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(MColor.accent))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shopSubscribe")
    }

    private var askChip: some View {
        Button(action: onAsk) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.caption)
                Text("Ask for something else").font(.caption.weight(.semibold))
            }
            .foregroundStyle(MColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain).glassPill()
        .accessibilityIdentifier("shopAsk")
    }

    private var addChip: some View {
        Button { onEdit(nil) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.caption.weight(.bold))
                Text(myOffers.isEmpty ? "Set your prices" : "Add").font(.caption.weight(.semibold))
            }
            .foregroundStyle(MColor.accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain).glassPill()
        .accessibilityIdentifier("shopAddOffer")
    }

    /// The thing creators on this kind of platform actually sell in a DM.
    private var lockedPhotoChip: some View {
        Button(action: onLockedPhoto) {
            HStack(spacing: 7) {
                Image(systemName: MSymbol.locked).font(.caption)
                Text("Locked photo").font(.caption.weight(.semibold))
            }
            .foregroundStyle(MColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain).glassPill()
        .accessibilityIdentifier("shopLockedPhoto")
    }
}
