import SwiftUI

/// "Rahul is out for drinks" — a NOW status with JOIN. When people join, it can become a Moment.
struct NowStatusRow: View {
    @Environment(AppEnvironment.self) private var env
    let post: NowPost
    @State private var made: SocialMoment?
    var body: some View {
        let mine = post.authorID == env.social.myID
        let joined = post.joinerIDs.contains(env.social.myID)
        HStack(spacing: MSpacing.m) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(userID: post.authorID, name: post.authorName, size: 44)
                Text(post.activity.emoji).font(.caption).padding(3).background(MColor.surface, in: Circle()).offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mine ? "You" : post.authorName.split(separator: " ").first.map(String.init) ?? post.authorName) \(mine ? post.activity.line.replacingOccurrences(of: "is ", with: "are ").replacingOccurrences(of: "wants", with: "want") : post.activity.line)").font(MFont.headline)
                HStack(spacing: 4) {
                    if !post.text.isEmpty { Text(post.text).lineLimit(1) }
                    if let p = post.coarsePlace { Text("· \(p)") }
                    Text("· \(post.createdAt.formatted(.relative(presentation: .named)))")
                }
                .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                if !post.joinerNames.isEmpty {
                    HStack(spacing: 6) { AvatarStack(names: post.joinerNames, size: 18); Text("\(post.joinerNames.count) in").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                }
            }
            Spacer()
            if mine {
                if !post.joinerIDs.isEmpty, post.savedToMomentID == nil {
                    Button("Make it a Moment") { Task { if let m = await env.social.makeMoment(from: post) { env.toast("Moment started."); env.social.pendingMomentID = m.id } } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("makeMoment-\(post.id)")
                }
            } else if joined {
                Label("In", systemImage: "checkmark").font(MFont.caption.weight(.semibold)).foregroundStyle(MColor.success)
            } else {
                Button("JOIN") { Task { await env.social.joinNow(post) } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("joinNow-\(post.id)")
            }
        }
        .momentCard(padding: MSpacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// Home strip: everyone who's up for something right now.
struct AnyoneUpSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showComposer: Bool
    var body: some View {
        let statuses = env.social.nowPosts.filter(\.isStatus)
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack {
                Text("ANYONE UP?").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                Spacer()
                Button { showComposer = true } label: { Label("I'm up for…", systemImage: "hand.wave") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("imUpFor")
            }
            if statuses.isEmpty {
                Text("Nobody's out yet. Say what you're up for and see who joins.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            } else {
                ForEach(statuses) { NowStatusRow(post: $0) }
            }
        }
    }
}

/// One-screen "I'm up for…" composer: pick an activity, optional line and place, how long it lasts.
struct AnyoneUpComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var activity: NowPost.Activity = .drinks
    @State private var text = ""
    @State private var place = ""
    @State private var hours = 4.0
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("What are you up for?").font(MFont.title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: MSpacing.s) {
                    ForEach(NowPost.Activity.allCases.filter { $0 != .none }, id: \.self) { a in
                        Button { activity = a; Haptics.selection() } label: {
                            VStack(spacing: 4) { Text(a.emoji).font(.title2); Text(a.label).font(MFont.caption) }
                                .frame(maxWidth: .infinity).padding(.vertical, MSpacing.m)
                                .background(activity == a ? MColor.accentSoft : MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous).strokeBorder(activity == a ? MColor.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("activity-\(a.rawValue)")
                    }
                }
                TextField("Anyone out? (optional)", text: $text).textFieldStyle(.plain).padding(MSpacing.m).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                TextField("Where, roughly (city or area)", text: $place).textFieldStyle(.plain).padding(MSpacing.m).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lasts \(Int(hours)) hours").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    Slider(value: $hours, in: 1...12, step: 1).tint(MColor.accent)
                }
                Text("Friends you follow back see this. Your exact location is never shared.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                Spacer()
            }
            .padding(MSpacing.l)
            .background(MColor.background)
            .navigationTitle("I'm up for…").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Post") { Task { if await env.social.postNow(text: text, photo: nil, place: place.isBlank ? nil : place, activity: activity, hours: hours) { Haptics.completed(); dismiss() } } }.accessibilityIdentifier("postStatus") }
            }
        }
        .presentationDetents([.large])
    }
}
