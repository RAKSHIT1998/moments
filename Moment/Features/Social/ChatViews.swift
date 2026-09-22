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
    @State private var showPPV = false
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
                        let seen = env.social.seenNames(for: conversationID)
                        if !seen.isEmpty, messages.last?.authorID == env.social.myID {
                            Text(conversation?.isGroup == true ? "Seen by \(seen.joined(separator: ", "))" : "Seen").font(MFont.caption).foregroundStyle(MColor.textTertiary).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 6)
                                .accessibilityIdentifier("seenLine")
                        }
                        let _ = env.social.typingTick
                        let typing = env.social.typingNames(for: conversationID)
                        if !typing.isEmpty {
                            HStack(spacing: 6) {
                                TypingDots()
                                Text(typing.count == 1 ? "\(typing[0].split(separator: " ").first.map(String.init) ?? typing[0]) is typing" : "\(typing.count) people are typing").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7).glassPill().frame(maxWidth: .infinity, alignment: .leading).id("typing")
                            .accessibilityIdentifier("typingIndicator")
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
        .sheet(isPresented: $showPPV) { PayPerViewComposer(conversationID: conversationID, buyerID: otherID) }
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
                            Text(quoted.text.isEmpty ? (quoted.momentID != nil ? "A Moment" : (quoted.media?.kind == .voice ? "Voice note" : "Photo")) : quoted.text).font(MFont.caption).lineLimit(2)
                        }
                        .foregroundStyle(MColor.textSecondary)
                    }
                    .padding(8).glass(radius: 10)
                }
                if let momentID = m.momentID { momentCard(momentID) }
                if m.isPayPerView { PayPerViewBubble(message: m, mine: mine) }
                else if let media = m.media, media.kind == .voice { VoiceNoteBubble(message: m, mine: mine) }
                else if let media = m.media { SocialImage(ref: media).frame(width: 230, height: 230).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5)) }
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
                if env.social.isCreator, conversation?.isGroup != true {
                    Button { showPPV = true } label: { Image(systemName: "lock.fill").font(.title3).foregroundStyle(MColor.accent) }
                        .frame(width: 36, height: 36).accessibilityLabel("Send a locked photo").accessibilityIdentifier("ppvButton")
                }
                TextField("Message", text: $text, axis: .vertical).lineLimit(1...5).focused($focused).textFieldStyle(.plain)
                    .padding(.horizontal, MSpacing.m).padding(.vertical, 9)
                    .glass(radius: 20)
                    .accessibilityIdentifier("messageField")
                    .onChange(of: text) { _, t in if !t.isEmpty { env.social.noteTyping(conversationID) } }
                if text.isBlank {
                    VoiceRecordButton { url in
                        let r = replyTo?.id; replyTo = nil
                        Task { if let d = try? Data(contentsOf: url) { _ = await env.social.send(conversationID: conversationID, text: "", voice: d, replyTo: r) }; try? FileManager.default.removeItem(at: url) }
                    }
                } else {
                    Button { let t = text, r = replyTo?.id; text = ""; replyTo = nil; Task { _ = await env.social.send(conversationID: conversationID, text: t, replyTo: r) } } label: {
                        Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white).frame(width: 36, height: 36)
                            .background(Circle().fill(MColor.accent))
                    }
                    .accessibilityLabel("Send").accessibilityIdentifier("sendMessage")
                }
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

/// Three dots breathing in turn.
struct TypingDots: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(MColor.textSecondary).frame(width: 6, height: 6).opacity(on ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { if !ProcessInfo.processInfo.arguments.contains("-uitest") { on = true } }
        .accessibilityHidden(true)
    }
}

/// A locked photo in a chat. The price is on it; unlocking buys the hidden set behind it.
struct PayPerViewBubble: View {
    @Environment(AppEnvironment.self) private var env
    let message: DirectMessage
    var mine: Bool
    @State private var unlocking = false
    private var unlocked: Bool { message.vaultSetID.map { env.social.hasBought($0) } ?? false || mine }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if unlocked, let setID = message.vaultSetID {
                NavigationLink(value: SocialRoute.vaultSet(setID)) {
                    ZStack {
                        SecureMediaView(ref: env.social.items(setID).first?.media ?? env.social.sets(of: message.authorID).first { $0.id == setID }?.cover, creatorID: message.authorID)
                            .frame(width: 230, height: 300)
                    }
                }
                .buttonStyle(.plain)
                .task { await env.social.loadItems(setID) }
            } else {
                ZStack {
                    Rectangle().fill(MColor.fill).frame(width: 230, height: 300)
                    VStack(spacing: MSpacing.m) {
                        Image(systemName: "lock.fill").font(.title).foregroundStyle(MColor.textSecondary)
                        Button {
                            unlocking = true
                            Task { _ = await env.social.unlockMessage(message); unlocking = false }
                        } label: {
                            Group { if unlocking { ProgressView().tint(.white) } else { Text("Unlock · \((Double(message.priceMinor) / 100).formatted(.currency(code: message.currency).precision(.fractionLength(0))))") } }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Capsule().fill(MColor.accent))
                        }
                        .buttonStyle(.plain).disabled(unlocking).accessibilityIdentifier("unlockMessage-\(message.id)")
                    }
                }
            }
            if !message.text.isEmpty {
                Text(message.text).font(MFont.caption).foregroundStyle(mine ? .white : MColor.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(mine ? MColor.accent : MColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("ppv-\(message.id)")
    }
}

/// Creator side: pick a photo, put a price on it, send it into this chat.
struct PayPerViewComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let conversationID: String
    let buyerID: String
    @State private var item: PhotosPickerItem?
    @State private var data: Data?
    @State private var price = "499"
    @State private var caption = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Send a locked photo").font(MFont.title)
            PhotosPicker(selection: $item, matching: .images) {
                ZStack {
                    if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
                    else { VStack(spacing: 8) { Image(systemName: "photo.badge.plus").font(.largeTitle); Text("Choose a photo").font(MFont.subheadline) }.foregroundStyle(MColor.textSecondary) }
                }
                .frame(maxWidth: .infinity).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 16)).glass(radius: 16)
            }
            .accessibilityIdentifier("ppvPhoto")
            HStack(spacing: MSpacing.s) {
                Text("₹").font(MFont.hero).foregroundStyle(MColor.textSecondary)
                TextField("499", text: $price).keyboardType(.numberPad).font(MFont.hero).accessibilityIdentifier("ppvPrice")
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m).glass(radius: 16)
            TextField("Say something with it", text: $caption).padding(MSpacing.m).glass(radius: 14)
            Spacer(minLength: 0)
            Button {
                guard let data, let minor = Int(price.filter(\.isNumber)), minor > 0 else { return }
                Task { if await env.social.sendPayPerView(conversationID: conversationID, to: buyerID, photo: data, priceMinor: minor * 100, caption: caption) != nil { dismiss() } }
            } label: { if env.social.busy { ProgressView().tint(.white) } else { Text("Send locked").frame(maxWidth: .infinity) } }
            .buttonStyle(PrimaryButtonStyle()).disabled(data == nil || env.social.busy).accessibilityIdentifier("sendPPV")
            Text("They see a locked tile with the price. Screenshots of it come out blank on iPhone, and every view carries their MOMENT ID.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
        }
        .padding(MSpacing.page).background(LiquidBackdrop())
        .onChange(of: item) { _, i in Task { if let i, let d = try? await i.loadTransferable(type: Data.self) { data = d } } }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}
