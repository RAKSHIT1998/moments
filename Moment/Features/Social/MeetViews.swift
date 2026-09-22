import SwiftUI

// MARK: - Meet: people you've actually crossed paths with

struct MeetView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var noteFor: MeetRanker.Candidate?
    @State private var matched: MeetMatch?
    /// Crossed paths (default) or Tonight: only people who are out right now, nearest first.
    @State private var tonight = false
    private var shown: [MeetRanker.Candidate] {
        tonight ? env.social.meetCandidates.filter { $0.overlaps.contains { $0.kind == .nearbyNow } } : env.social.meetCandidates
    }

    var body: some View {
        Group {
            if env.social.myDating == nil { intro }
            else if shown.isEmpty { empty }
            else { stack }
        }
        .safeAreaInset(edge: .top) {
            if env.social.myDating != nil {
                Picker("Mode", selection: $tonight) { Text("Crossed paths").tag(false); Text("Tonight").tag(true) }
                    .pickerStyle(.segmented).padding(.horizontal, MSpacing.page).padding(.vertical, 6).background(.ultraThinMaterial)
                    .accessibilityIdentifier("meetMode")
            }
        }
        .background(LiquidBackdrop(tint: .pink))
        .navigationTitle("Meet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if env.social.myDating != nil {
                    NavigationLink(value: SocialRoute.meetLikes) {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                            .overlay(alignment: .topTrailing) { let n = env.social.likesReceived.count; if n > 0 { Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(3).background(Circle().fill(MColor.danger)).offset(x: 8, y: -8) } }
                    }
                    .accessibilityIdentifier("meetLikes")
                    NavigationLink(value: SocialRoute.meetSetup) { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Edit Meet profile")
                }
            }
        }
        .task {
            if let loc = env.location.current { await env.social.refreshNearby(latitude: loc.latitude, longitude: loc.longitude) }
            await env.social.refreshMeet()
        }
        .sheet(item: $noteFor) { c in LikeNoteSheet(candidate: c) { note, prompt in noteFor = nil; Task { if let m = await env.social.like(c, note: note, prompt: prompt) { matched = m } } } }
        .sheet(item: $matched) { m in MatchSheet(match: m) }
        .modifier(SocialErrorAlert())
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                Text("Meet people you've\nactually crossed paths with.").font(MFont.hero).lineSpacing(2)
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    row("Same night, same place", "You only see people who were at a Moment, a venue or a ritual you were at — or who are out right now nearby. No strangers, no infinite stack.")
                    row("Photos from real Moments", "Profiles use sides people actually posted. Nothing uploaded just to look good.")
                    row("Private by design", "Opt in; hide from people you know; a like is sealed so only the person you liked can see it. No one else — not us — learns who likes whom.")
                    row("Matches become plans", "A match opens a chat that starts with why you're talking. The ice-breaker is a real invite: \"Last light, Friday?\"")
                }
                NavigationLink(value: SocialRoute.meetSetup) { Text("Set up Meet").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle(tint: .pink)).accessibilityIdentifier("meetSetup")
                Text("18+. You can leave any time; leaving removes your profile everywhere.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.page)
        }
    }
    private func row(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(MFont.headline); Text(d).font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    private var empty: some View {
        VStack(spacing: MSpacing.m) {
            Spacer()
            Text(env.social.meetLoaded ? (tonight ? "Nobody's out near you right now." : "Nobody new who's crossed your path.") : "Looking…").font(MFont.title)
            Text(tonight ? "Post a NOW yourself — people who are out tonight see each other here first." : "Go to a ritual, join a NOW, add your side to a night — the overlap is what shows people to you.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center)
            NavigationLink(value: SocialRoute.now) { Text("See who's out now") }.buttonStyle(GlassButtonStyle())
            Spacer()
        }
        .padding(MSpacing.page)
    }

    private var stack: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(shown) { c in
                    MeetCard(candidate: c, onLike: { noteFor = c }, onPass: { Task { await env.social.pass(c) } })
                        .containerRelativeFrame(.vertical)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// One person. Photo, the overlap first, then who they are. Like the photo or a prompt.
struct MeetCard: View {
    @Environment(AppEnvironment.self) private var env
    let candidate: MeetRanker.Candidate
    var onLike: () -> Void
    var onPass: () -> Void
    @State private var photo = 0
    private var p: DatingProfile { candidate.profile }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if p.photos.isEmpty { Color(uiColor: .secondarySystemBackground) } else { SocialImage(ref: p.photos[min(photo, p.photos.count - 1)]).aspectRatio(contentMode: .fill) }
                }
                .frame(width: g.size.width, height: g.size.height).clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .onTapGesture { if p.photos.count > 1 { photo = (photo + 1) % p.photos.count } }
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    if let o = candidate.overlaps.first {
                        Label(o.label, systemImage: o.kind == .nearbyNow ? "bolt.fill" : "checkmark.seal.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8).glassPill(tint: .pink)
                            .accessibilityIdentifier("overlap-\(p.userID)")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.displayName.split(separator: " ").first.map(String.init) ?? p.displayName).font(MFont.hero).foregroundStyle(.white)
                        Text("\(p.age)").font(MFont.title).foregroundStyle(.white.opacity(0.85))
                    }
                    HStack(spacing: 6) {
                        Text(p.intent.label).font(MFont.caption).padding(.horizontal, 10).padding(.vertical, 5).glassPill()
                        if candidate.overlaps.count > 1 { Text("+\(candidate.overlaps.count - 1) more in common").font(MFont.caption).padding(.horizontal, 10).padding(.vertical, 5).glassPill() }
                    }
                    .foregroundStyle(.white)
                    if let pr = p.prompts.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pr.question.uppercased()).font(MFont.eyebrow).tracking(1).foregroundStyle(.white.opacity(0.7))
                            Text(pr.answer).font(MFont.body).foregroundStyle(.white).lineLimit(3)
                        }
                        .padding(MSpacing.m).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 16)
                    }
                    HStack(spacing: MSpacing.m) {
                        Button(action: onPass) { Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white).frame(width: 56, height: 56) }
                            .buttonStyle(.plain).glass(radius: 28).accessibilityLabel("Pass").accessibilityIdentifier("pass-\(p.userID)")
                        Button(action: onLike) { HStack(spacing: 8) { Image(systemName: "heart.fill"); Text("Like") }.font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 56) }
                            .buttonStyle(.plain).background(Capsule().fill(LinearGradient(colors: [.pink, .pink.opacity(0.75)], startPoint: .top, endPoint: .bottom))).overlay(Glass.rim(Capsule(), strength: 0.8)).clipShape(Capsule())
                            .accessibilityIdentifier("like-\(p.userID)")
                        NavigationLink(value: SocialRoute.profile(p.userID)) { Image(systemName: "person").font(.title3).foregroundStyle(.white).frame(width: 56, height: 56) }
                            .buttonStyle(.plain).glass(radius: 28).accessibilityLabel("Profile")
                    }
                }
                .padding(MSpacing.page).padding(.bottom, 96)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetCard-\(p.userID)")
    }
}

/// Say something about a prompt or the photo. Hinge's best idea, kept.
struct LikeNoteSheet: View {
    let candidate: MeetRanker.Candidate
    var onSend: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var prompt: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Like \(candidate.profile.displayName.split(separator: " ").first.map(String.init) ?? "")").font(MFont.title)
            if !candidate.profile.prompts.isEmpty {
                Text("ABOUT").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        Button { prompt = nil } label: { Text("Their photo") }.buttonStyle(ChipButtonStyle(prominent: prompt == nil))
                        ForEach(candidate.profile.prompts, id: \.question) { pr in Button { prompt = pr.question } label: { Text(pr.question) }.buttonStyle(ChipButtonStyle(prominent: prompt == pr.question)) }
                    }
                }
            }
            TextField("Say something real (optional)", text: $note, axis: .vertical).lineLimit(2...4).padding(MSpacing.m).glass(radius: 14).accessibilityIdentifier("likeNote")
            Button { onSend(note.trimmed, prompt) } label: { Text("Send like").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle(tint: .pink)).accessibilityIdentifier("sendLike")
            Text("Only they can see this. If they like you back, you match and a chat opens.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            Spacer()
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .pink))
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
    }
}

struct MatchSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let match: MeetMatch
    var body: some View {
        VStack(spacing: MSpacing.xl) {
            Spacer()
            Text("It's a match.").font(MFont.hero)
            if let o = match.overlaps.first { Text(o.label).font(MFont.title).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center) }
            if let other = match.other(than: env.social.myID) {
                HStack(spacing: -12) { AvatarView(userID: env.social.myID, name: env.social.displayName, size: 80); AvatarView(userID: other.id, name: other.name, size: 80) }
                if let cid = match.conversationID {
                    NavigationLink(value: SocialRoute.conversation(cid)) { Text("Say hi to \(other.name.split(separator: " ").first.map(String.init) ?? other.name)").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle(tint: .pink)).simultaneousGesture(TapGesture().onEnded { dismiss() })
                }
            }
            Button("Later") { dismiss() }.font(MFont.subheadline)
            Spacer()
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .pink))
        .accessibilityIdentifier("matchSheet")
    }
}

// MARK: - Setup

struct MeetSetupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var birthYear = 1998
    @State private var gender: DatingProfile.Gender = .woman
    @State private var seeking: Set<DatingProfile.Gender> = Set(DatingProfile.Gender.allCases)   // everyone, until you narrow it
    @State private var intent: DatingProfile.Intent = .dates
    @State private var prompts: [DatingProfile.Prompt] = [.init(question: DatingProfile.promptBank[0], answer: ""), .init(question: DatingProfile.promptBank[2], answer: ""), .init(question: DatingProfile.promptBank[7], answer: "")]
    @State private var photos: [MediaRef] = []
    @State private var bio = ""
    @State private var hideFromKnown = false
    @State private var overlapOnly = true
    @State private var saving = false
    @State private var confirmLeave = false
    private var years: [Int] { let y = Calendar.current.component(.year, from: .now); return Array((y - 80)...(y - 18)).reversed() }
    private var valid: Bool { !seeking.isEmpty && prompts.contains { !$0.answer.isBlank } && !photos.isEmpty }

    var body: some View {
        Form {
            Section("Photos from your Moments") {
                let pool = env.social.myPhotosForMeet
                if pool.isEmpty { Text("Add a side to a Moment first — Meet only uses photos you've actually posted.").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pool.prefix(30).enumerated()), id: \.offset) { _, ref in
                            let on = photos.contains(ref)
                            Button { if on { photos.removeAll { $0 == ref } } else if photos.count < 6 { photos.append(ref) } } label: {
                                SocialImage(ref: ref).frame(width: 84, height: 112).clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Color.pink : .clear, lineWidth: 3))
                                    .overlay(alignment: .topTrailing) { if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.pink).padding(4) } }
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("meetPhoto-\(ref.remoteID ?? ref.localRef ?? "")")
                        }
                    }
                }
                Text("\(photos.count)/6 chosen").font(MFont.caption).foregroundStyle(MColor.textSecondary)
            }
            Section("You") {
                Picker("Born", selection: $birthYear) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }
                Picker("I'm a", selection: $gender) { ForEach(DatingProfile.Gender.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("Looking for", selection: $intent) { ForEach(DatingProfile.Intent.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("A line about you (optional)", text: $bio)
            }
            Section("Show me") {
                ForEach(DatingProfile.Gender.allCases, id: \.self) { g in
                    Toggle(g.label, isOn: Binding(get: { seeking.contains(g) }, set: { if $0 { seeking.insert(g) } else { seeking.remove(g) } })).accessibilityIdentifier("seek-\(g.rawValue)")
                }
            }
            Section("Prompts") {
                ForEach($prompts.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Menu { ForEach(DatingProfile.promptBank, id: \.self) { q in Button(q) { prompts[i].question = q } } } label: { HStack { Text(prompts[i].question).font(.subheadline.weight(.semibold)); Image(systemName: "chevron.down").font(.caption) }.foregroundStyle(MColor.textPrimary) }
                        TextField("Your answer", text: $prompts[i].answer, axis: .vertical).lineLimit(1...3).accessibilityIdentifier("prompt-\(i)")
                    }
                }
            }
            Section {
                Toggle("Only people I've crossed paths with", isOn: $overlapOnly)
                Toggle("Hide from people I know", isOn: $hideFromKnown)
            } footer: { Text("Crossed paths = same Moment, same venue this month, same ritual, or out right now nearby. Hiding from people you know keeps you out of the stacks of anyone you follow or who follows you.") }
            Section {
                Button { saving = true; Task { let ok = await env.social.saveDating(DatingProfile(userID: env.social.myID, displayName: env.social.displayName, birthYear: birthYear, gender: gender, seeking: Array(seeking), intent: intent, prompts: prompts.filter { !$0.answer.isBlank }, photos: photos, bio: bio.trimmed, hideFromKnown: hideFromKnown, overlapOnly: overlapOnly, updatedAt: .now)); saving = false; if ok { dismiss() } } } label: { Text(env.social.myDating == nil ? "Turn on Meet" : "Save").frame(maxWidth: .infinity) }
                    .disabled(!valid || saving).accessibilityIdentifier("saveMeet")
                if env.social.myDating != nil {
                    Button("Leave Meet", role: .destructive) { confirmLeave = true }
                        .confirmationDialog("Leave Meet?", isPresented: $confirmLeave) { Button("Leave", role: .destructive) { Task { await env.social.leaveMeet(); dismiss() } } } message: { Text("Your Meet profile is removed everywhere. Matches keep their chats.") }
                }
            }
        }
        .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .pink))
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(env.social.myDating == nil ? "Set up Meet" : "Meet profile")
        .onAppear { if let d = env.social.myDating { birthYear = d.birthYear; gender = d.gender; seeking = Set(d.seeking); intent = d.intent; if !d.prompts.isEmpty { prompts = d.prompts }; photos = d.photos; bio = d.bio; hideFromKnown = d.hideFromKnown; overlapOnly = d.overlapOnly } }
        .task { if env.social.myPhotosForMeet.isEmpty { for m in env.social.momentsImIn.prefix(6) { _ = await env.social.loadMoment(m.id) } } }
    }
}

// MARK: - Likes & matches

struct MeetLikesView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            if !env.social.meetMatches.isEmpty {
                Section("Matches") {
                    ForEach(env.social.meetMatches) { m in
                        if let other = m.other(than: env.social.myID) {
                            Button { Task { await env.social.openMatchChat(m); if let cid = env.social.meetMatches.first(where: { $0.id == m.id })?.conversationID { env.social.pendingConversationID = cid } } } label: {
                                HStack(spacing: MSpacing.m) {
                                    AvatarView(userID: other.id, name: other.name, size: 44)
                                    VStack(alignment: .leading, spacing: 2) { Text(other.name).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary); Text(m.overlaps.first?.label ?? "You matched").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                                    Spacer(); Image(systemName: "bubble.left.fill").foregroundStyle(.pink)
                                }
                            }
                            .accessibilityIdentifier("match-\(other.id)")
                        }
                    }
                }
            }
            Section(env.social.likesReceived.isEmpty ? "Likes" : "Likes you") {
                if env.social.likesReceived.isEmpty { Text("Nobody yet. Likes are sealed to you — nobody else, not even relays, can read them.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                ForEach(env.social.likesReceived) { l in
                    NavigationLink(value: SocialRoute.profile(l.fromID)) {
                        HStack(spacing: MSpacing.m) {
                            AvatarView(userID: l.fromID, name: l.fromName, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.fromName).font(.subheadline.weight(.semibold))
                                if !l.note.isEmpty { Text(l.promptQuestion.map { "On “\($0)”: " } ?? "" + "“\(l.note)”").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(2) }
                            }
                        }
                    }
                    .accessibilityIdentifier("likeFrom-\(l.fromID)")
                }
            }
        }
        .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .pink))
        .navigationTitle("Likes")
        .navigationDestination(item: Binding(get: { env.social.pendingConversationID.map { BoxedID(id: $0) } }, set: { _ in env.social.pendingConversationID = nil })) { b in ChatView(conversationID: b.id) }
        .task { await env.social.refreshMeet() }
    }
}
