import SwiftUI
import PhotosUI

// MARK: - Chats (tab)

/// Every conversation, groups first if they're active. Unread is decided on this phone only.
struct ChatsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var showNew = false
    @State private var open: Conversation?

    private var list: [Conversation] {
        let q = query.lowercased().trimmed
        return env.social.conversations.filter { q.isEmpty || displayName($0).lowercased().contains(q) || $0.lastMessage.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: MSpacing.s) {
                    if env.social.conversations.isEmpty && env.social.hasLoadedOnce {
                        VStack(spacing: MSpacing.m) {
                            Text("Nobody yet.").font(MFont.title)
                            Text("Message a friend, or open your group's chat. Every chat is encrypted between the people in it — no server reads it.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center)
                            Button("New message") { showNew = true }.buttonStyle(GlassButtonStyle(filled: true))
                        }
                        .padding(MSpacing.xl).frame(maxWidth: .infinity).glass().padding(.top, MSpacing.xl)
                    }
                    if !env.social.groups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MSpacing.s) {
                                ForEach(env.social.groups) { g in
                                    Button { Task { if let c = await env.social.groupConversation(g) { open = c } } } label: {
                                        HStack(spacing: 6) { Text(g.emoji); Text(g.name).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary) }
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                    }
                                    .buttonStyle(.plain).glassPill()
                                    .accessibilityIdentifier("groupChat-\(g.id)")
                                }
                            }
                            .padding(.horizontal, MSpacing.page).padding(.vertical, 4)
                        }
                    }
                    ForEach(list) { c in
                        Button { open = c } label: { row(c) }.buttonStyle(.plain)
                            .accessibilityIdentifier("chat-\(c.id)")
                    }
                }
                .padding(.horizontal, MSpacing.page)
                .padding(.bottom, 90)
            }
            .background(LiquidBackdrop())
            .searchable(text: $query, prompt: "People, groups, messages")
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message").accessibilityIdentifier("newMessage")
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: SocialRoute.inbox) {
                        Image(systemName: "bell").overlay(alignment: .topTrailing) { if env.social.unreadActivity > 0 { Circle().fill(MColor.danger).frame(width: 8, height: 8).offset(x: 2, y: -2) } }
                    }
                    .accessibilityLabel("Activity").accessibilityIdentifier("chatsInboxButton")
                }
            }
            .navigationDestination(item: $open) { c in ChatView(conversationID: c.id) }
            .sheet(isPresented: $showNew) { NewMessageSheet { c in showNew = false; open = c } }
            .socialDestinations()
            .refreshable { await env.social.refreshInbox() }
            .task { await env.social.refreshInbox(); await env.social.refreshGroups() }
        }
        .modifier(SocialErrorAlert())
    }

    private func displayName(_ c: Conversation) -> String {
        if let t = c.title { return t }
        return zip(c.participantIDs, c.participantNames).first { $0.0 != env.social.myID }?.1 ?? "Chat"
    }
    private func otherID(_ c: Conversation) -> String { c.participantIDs.first { $0 != env.social.myID } ?? "" }

    private func row(_ c: Conversation) -> some View {
        let unread = env.social.isUnread(c)
        return HStack(spacing: MSpacing.m) {
            if c.isGroup {
                ZStack { Circle().fill(MColor.accentSoft); Text(c.emoji ?? "👥").font(.title2) }.frame(width: 52, height: 52)
            } else {
                AvatarView(userID: otherID(c), name: displayName(c), size: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName(c)).font(.subheadline.weight(unread ? .bold : .semibold)).foregroundStyle(MColor.textPrimary)
                    Spacer()
                    Text(c.updatedAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                HStack(spacing: 6) {
                    if unread { Circle().fill(MColor.accent).frame(width: 8, height: 8) }
                    Text(c.lastMessage.isEmpty ? (c.isGroup ? "\(c.participantIDs.count) people" : "Say hi") : c.lastMessage).font(MFont.subheadline).foregroundStyle(unread ? MColor.textPrimary : MColor.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(MSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 18, tint: unread ? MColor.accent : nil)
    }
}

/// Pick a person (or a group) to start with.
struct NewMessageSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onOpen: (Conversation) -> Void
    @State private var query = ""
    @State private var results: [SocialUser] = []
    var body: some View {
        NavigationStack {
            List {
                if !env.social.groups.isEmpty { Section("Groups") { ForEach(env.social.groups) { g in groupRow(g) } } }
                Section("People") { ForEach(results) { u in personRow(u) } }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop())
            .searchable(text: $query, prompt: "Name or @handle")
            .navigationTitle("New message")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { results = await env.social.search(people: "") }
            .onChange(of: query) { _, q in Task { results = await env.social.search(people: q) } }
        }
    }
    private func groupRow(_ g: SocialGroup) -> some View {
        Button { Task { if let c = await env.social.groupConversation(g) { onOpen(c) } } } label: {
            HStack { Text(g.emoji); Text(g.name); Spacer(); Text("\(g.memberIDs.count)").foregroundStyle(MColor.textSecondary) }
        }
    }
    private func personRow(_ u: SocialUser) -> some View {
        Button { Task { if let c = await env.social.conversation(with: u.id) { onOpen(c) } } } label: {
            HStack(spacing: MSpacing.m) {
                AvatarView(userID: u.id, name: u.displayName, size: 36)
                VStack(alignment: .leading) { Text(u.displayName); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
            }
        }
        .accessibilityIdentifier("newChat-\(u.id)")
    }
}

// MARK: - Chat (thread)

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    let conversationID: String
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showMomentPicker = false
    @State private var replyTo: DirectMessage?
    @State private var reactTarget: DirectMessage?
    @FocusState private var focused: Bool

    private var conversation: Conversation? { env.social.conversations.first { $0.id == conversationID } }
    private var messages: [DirectMessage] { (env.social.messages[conversationID] ?? []).filter { !$0.isReaction } }
    private var otherID: String { conversation?.participantIDs.first { $0 != env.social.myID } ?? "" }
    private var title: String {
        if let t = conversation?.title { return t }
        return zip(conversation?.participantIDs ?? [], conversation?.participantNames ?? []).first { $0.0 != env.social.myID }?.1 ?? "Chat"
    }
    private let quick = ["❤️", "🔥", "😂", "🙌", "😮", "😢"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !Calendar.current.isDate(m.createdAt, inSameDayAs: messages[i - 1].createdAt) {
                                Text(m.createdAt.formatted(date: .abbreviated, time: .omitted)).font(MFont.caption).foregroundStyle(MColor.textSecondary).padding(.vertical, 6).padding(.horizontal, 12).glassPill().padding(.vertical, 8)
                            }
                            bubble(m, showName: (conversation?.isGroup ?? false) && m.authorID != env.social.myID && (i == 0 || messages[i - 1].authorID != m.authorID))
                                .id(m.id)
                        }
                    }
                    .padding(.horizontal, MSpacing.l).padding(.top, MSpacing.m).padding(.bottom, MSpacing.s)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            composer
        }
        .background(LiquidBackdrop())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if conversation?.isGroup == true {
                        ForEach(Array(zip(conversation?.participantIDs ?? [], conversation?.participantNames ?? [])), id: \.0) { id, name in
                            NavigationLink(value: SocialRoute.profile(id)) { Label(name, systemImage: "person") }
                        }
                    } else {
                        NavigationLink(value: SocialRoute.profile(otherID)) { Label("Profile", systemImage: "person") }
                        Button("Block", systemImage: "hand.raised", role: .destructive) { Task { await env.social.block(otherID) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await env.social.loadMessages(conversationID); env.social.markRead(conversationID) }
        .onChange(of: pickerItem) { _, item in Task { if let item, let d = try? await item.loadTransferable(type: Data.self) { _ = await env.social.send(conversationID: conversationID, text: "", photo: d, replyTo: replyTo?.id); replyTo = nil; pickerItem = nil } } }
        .sheet(isPresented: $showMomentPicker) { MomentPickerSheet { m in Task { _ = await env.social.send(conversationID: conversationID, text: m.title, momentID: m.id); showMomentPicker = false } } }
        .overlay { if let t = reactTarget { reactionPicker(for: t) } }
        .modifier(SocialErrorAlert())
    }

    // MARK: Bubbles

    private func bubble(_ m: DirectMessage, showName: Bool) -> some View {
        let mine = m.authorID == env.social.myID
        let reactions = env.social.reactions(on: m)
        return HStack(alignment: .bottom, spacing: MSpacing.s) {
            if mine { Spacer(minLength: 56) } else { AvatarView(userID: m.authorID, name: m.authorName, size: 26).opacity(showName || conversation?.isGroup == false ? 1 : 0) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if showName { Text(m.authorName).font(MFont.caption).foregroundStyle(MColor.textSecondary).padding(.horizontal, 6) }
                if let r = m.replyToID, let quoted = env.social.message(r, in: conversationID) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(MColor.accent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(quoted.authorID == env.social.myID ? "You" : quoted.authorName).font(.caption.weight(.semibold))
                            Text(quoted.text.isEmpty ? (quoted.momentID != nil ? "A Moment" : "Photo") : quoted.text).font(MFont.caption).lineLimit(2)
                        }
                        .foregroundStyle(MColor.textSecondary)
                    }
                    .padding(8).glass(radius: 10)
                }
                if let momentID = m.momentID { momentCard(momentID) }
                if let media = m.media { SocialImage(ref: media).frame(width: 230, height: 230).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5)) }
                if !m.text.isEmpty, m.momentID == nil || m.text != env.social.moments[m.momentID ?? ""]?.title {
                    Text(m.text).font(MFont.body)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(mine ? Color.white : MColor.textPrimary)
                        .background {
                            if mine {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                                    Glass.sheen(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    Glass.rim(RoundedRectangle(cornerRadius: 20, style: .continuous), strength: 0.8)
                                }
                            }
                        }
                        .modifier(GlassIf(enabled: !mine))
                        .accessibilityIdentifier("message-\(m.id)")
                }
                if !reactions.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(Dictionary(grouping: reactions, by: \.authorID).compactMap { $0.value.last }, id: \.id) { r in Text(r.text).font(.caption) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3).glassPill().offset(y: -4)
                }
                Text(m.createdAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(MColor.textTertiary).padding(.horizontal, 6)
            }
            .contextMenu {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTo = m; focused = true }
                Button("React", systemImage: "face.smiling") { reactTarget = m }
                if let momentID = m.momentID { NavigationLink(value: SocialRoute.moment(momentID)) { Label("Open Moment", systemImage: "rectangle.stack") } }
                if !m.text.isEmpty { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = m.text } }
            }
            .onLongPressGesture(minimumDuration: 0.35) { reactTarget = m; Haptics.saved() }
            if !mine { Spacer(minLength: 56) }
        }
    }
    private struct GlassIf: ViewModifier { var enabled: Bool; func body(content: Content) -> some View { if enabled { content.glass(radius: 20) } else { content } } }

    private func momentCard(_ id: String) -> some View {
        NavigationLink(value: SocialRoute.moment(id)) {
            VStack(alignment: .leading, spacing: 0) {
                if let moment = env.social.moments[id] {
                    SocialImage(ref: moment.coverRef).frame(width: 230, height: 150).clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moment.title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                        Text("\(moment.memberIDs.count) people · \(moment.dateLabel)").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                    .padding(MSpacing.s)
                } else {
                    Label("A Moment", systemImage: "rectangle.stack").padding(MSpacing.m)
                }
            }
            .glass(radius: 18)
        }
        .buttonStyle(.plain)
        .task { if env.social.moments[id] == nil { _ = await env.social.loadMoment(id) } }
    }

    private func reactionPicker(for m: DirectMessage) -> some View {
        ZStack {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { reactTarget = nil }
            HStack(spacing: 6) {
                ForEach(quick, id: \.self) { e in
                    Button { Task { await env.social.react(conversationID: conversationID, messageID: m.id, emoji: e) }; reactTarget = nil; Haptics.saved() } label: { Text(e).font(.title) }
                        .buttonStyle(.plain).accessibilityIdentifier("react-\(e)")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).glass(radius: 30, prominent: true)
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let r = replyTo {
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(MColor.accent).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(r.authorID == env.social.myID ? "yourself" : r.authorName)").font(.caption.weight(.semibold))
                        Text(r.text.isEmpty ? "Photo / Moment" : r.text).font(MFont.caption).lineLimit(1).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MColor.textTertiary) }
                }
                .padding(.horizontal, MSpacing.m).padding(.vertical, 6).glass(radius: 12)
            }
            HStack(spacing: MSpacing.s) {
                Button { showMomentPicker = true } label: { Image(systemName: "rectangle.stack.badge.plus").font(.title3) }.frame(width: 36, height: 36).accessibilityLabel("Share a Moment")
                PhotosPicker(selection: $pickerItem, matching: .images) { Image(systemName: "photo").font(.title3) }.frame(width: 36, height: 36)
                TextField("Message", text: $text, axis: .vertical).lineLimit(1...5).focused($focused).textFieldStyle(.plain)
                    .padding(.horizontal, MSpacing.m).padding(.vertical, 9)
                    .glass(radius: 20)
                    .accessibilityIdentifier("messageField")
                Button { let t = text, r = replyTo?.id; text = ""; replyTo = nil; Task { _ = await env.social.send(conversationID: conversationID, text: t, replyTo: r) } } label: {
                    Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white).frame(width: 36, height: 36)
                        .background(Circle().fill(text.isBlank ? MColor.textTertiary : MColor.accent))
                }
                .disabled(text.isBlank).accessibilityLabel("Send").accessibilityIdentifier("sendMessage")
            }
        }
        .padding(.horizontal, MSpacing.m).padding(.vertical, MSpacing.s)
        .background(.ultraThinMaterial)
    }
}

/// Reused by chat and by "Ask about the gap": pick one of my Moments.
struct MomentPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onPick: (SocialMoment) -> Void
    var body: some View {
        NavigationStack {
            List(env.social.momentsImIn) { m in
                Button { onPick(m) } label: { HStack { SocialImage(ref: m.coverRef).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(m.title).foregroundStyle(MColor.textPrimary); Text(m.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) } } }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop())
            .navigationTitle("Share a Moment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
