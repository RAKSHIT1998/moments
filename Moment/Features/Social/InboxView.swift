import SwiftUI
import PhotosUI

/// Inbox: activity on your Moments, invitations, and messages.
struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Inbox", selection: $segment) { Text("Activity").tag(0); Text("Invites").tag(1); Text("Messages").tag(2) }
                    .pickerStyle(.segmented).padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.s)
                    .accessibilityIdentifier("inboxSegments")
                List {
                    switch segment {
                    case 0: activity
                    case 1: invites
                    default: messages
                    }
                }
                .listStyle(.plain)
            }
            .background(MColor.background)
            .navigationTitle("Inbox")
            .refreshable { await env.social.refreshInbox() }
            .task { await env.social.refreshInbox(); await env.social.markActivityRead() }
            .socialDestinations()
        }
    }

    @ViewBuilder private var activity: some View {
        if env.social.activity.isEmpty { Text("When people add to your Moments or react, it shows here.").foregroundStyle(MColor.textSecondary).listRowSeparator(.hidden) }
        ForEach(env.social.activity) { a in
            Group {
                if let id = a.momentID {
                    NavigationLink(value: SocialRoute.moment(id)) { activityRow(a) }
                } else { activityRow(a) }
            }
            .listRowBackground(a.read ? Color.clear : MColor.accentSoft)
        }
    }

    private func activityRow(_ a: ActivityItem) -> some View {
        HStack(spacing: MSpacing.m) {
            PersonAvatar(name: a.actorName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.text).font(MFont.body)
                Text(a.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
        }
        .accessibilityIdentifier("activity-\(a.id)")
    }

    @ViewBuilder private var invites: some View {
        if env.social.invites.isEmpty { Text("Invitations to other people's Moments land here. Links opened from Messages open the Moment directly.").foregroundStyle(MColor.textSecondary).listRowSeparator(.hidden) }
        ForEach(env.social.invites) { inv in
            NavigationLink(value: SocialRoute.moment(inv.momentID)) {
                HStack(spacing: MSpacing.m) {
                    PersonAvatar(name: inv.inviterName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inv.momentTitle).font(MFont.headline)
                        Text("\(inv.inviterName) says you were there").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Text("ADD YOUR SIDE").font(MFont.eyebrow).foregroundStyle(MColor.accent)
                }
            }
            .accessibilityIdentifier("invite-\(inv.id)")
        }
    }

    @ViewBuilder private var messages: some View {
        if env.social.conversations.isEmpty { Text("Reply to a Moment or message a friend. Conversations stay between you.").foregroundStyle(MColor.textSecondary).listRowSeparator(.hidden) }
        ForEach(env.social.conversations) { c in
            NavigationLink(value: SocialRoute.conversation(c.id)) {
                HStack(spacing: MSpacing.m) {
                    PersonAvatar(name: otherName(c), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(otherName(c)).font(MFont.headline)
                        Text(c.lastMessage.isEmpty ? "Say hi" : c.lastMessage).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text(c.updatedAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
            }
            .accessibilityIdentifier("conversation-\(c.id)")
        }
    }

    private func otherName(_ c: Conversation) -> String {
        for (id, n) in zip(c.participantIDs, c.participantNames) where id != env.social.myID { return n }
        return c.participantNames.first ?? "Chat"
    }
}

/// 1:1 messages. A Moment can be dropped into the thread as a card.
struct ConversationView: View {
    @Environment(AppEnvironment.self) private var env
    let conversationID: String
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showMomentPicker = false
    @FocusState private var focused: Bool

    private var messages: [DirectMessage] { env.social.messages[conversationID] ?? [] }
    private var conversation: Conversation? { env.social.conversations.first { $0.id == conversationID } }
    private var otherID: String { conversation?.participantIDs.first { $0 != env.social.myID } ?? "" }
    private var otherName: String { zip(conversation?.participantIDs ?? [], conversation?.participantNames ?? []).first { $0.0 != env.social.myID }?.1 ?? "Chat" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: MSpacing.s) {
                        ForEach(messages) { m in bubble(m).id(m.id) }
                    }
                    .padding(MSpacing.l)
                }
                .onChange(of: messages.count) { _, _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            HStack(spacing: MSpacing.s) {
                Button { showMomentPicker = true } label: { Image(systemName: "rectangle.stack.badge.plus").font(.title3) }.accessibilityLabel("Share a Moment")
                PhotosPicker(selection: $pickerItem, matching: .images) { Image(systemName: "photo").font(.title3) }
                TextField("Message", text: $text, axis: .vertical).lineLimit(1...4).focused($focused).textFieldStyle(.plain).padding(.horizontal, MSpacing.m).padding(.vertical, 10)
                    .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                    .accessibilityIdentifier("messageField")
                Button { let t = text; text = ""; Task { _ = await env.social.send(conversationID: conversationID, text: t) } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(text.isBlank).accessibilityLabel("Send").accessibilityIdentifier("sendMessage")
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.s)
            .background(.bar)
        }
        .background(MColor.background)
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(value: SocialRoute.profile(otherID)) { Label("Profile", systemImage: "person") }
                    Button("Block", systemImage: "hand.raised", role: .destructive) { Task { await env.social.block(otherID) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await env.social.loadMessages(conversationID) }
        .onChange(of: pickerItem) { _, item in Task { if let item, let d = try? await item.loadTransferable(type: Data.self) { _ = await env.social.send(conversationID: conversationID, text: "", photo: d) } } }
        .sheet(isPresented: $showMomentPicker) {
            NavigationStack {
                List(env.social.momentsImIn) { m in
                    Button { Task { _ = await env.social.send(conversationID: conversationID, text: m.title, momentID: m.id); showMomentPicker = false } } label: { HStack { SocialImage(ref: m.coverRef).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)); Text(m.title).foregroundStyle(MColor.textPrimary) } }
                }
                .navigationTitle("Share a Moment")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMomentPicker = false } } }
            }
        }
    }

    private func bubble(_ m: DirectMessage) -> some View {
        let mine = m.authorID == env.social.myID
        return HStack {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if let momentID = m.momentID, let moment = env.social.moments[momentID] {
                    NavigationLink(value: SocialRoute.moment(momentID)) {
                        VStack(alignment: .leading, spacing: 0) {
                            SocialImage(ref: moment.coverRef).frame(width: 220, height: 140)
                            VStack(alignment: .leading, spacing: 2) { Text(moment.title).font(MFont.headline).foregroundStyle(MColor.textPrimary); Text("Moment · \(moment.dateLabel)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }.padding(MSpacing.s)
                        }
                        .background(MColor.surface).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if let momentID = m.momentID {
                    NavigationLink(value: SocialRoute.moment(momentID)) { Label("A Moment", systemImage: "rectangle.stack").padding(MSpacing.m).background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous)) }.buttonStyle(.plain)
                }
                if let media = m.media { SocialImage(ref: media).frame(width: 220, height: 220).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous)) }
                if !m.text.isEmpty, m.momentID == nil || m.text != env.social.moments[m.momentID ?? ""]?.title {
                    Text(m.text).padding(.horizontal, MSpacing.m).padding(.vertical, 10)
                        .background(mine ? AnyShapeStyle(MColor.accentGradient) : AnyShapeStyle(MColor.surface), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(mine ? .white : MColor.textPrimary)
                }
                Text(m.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(MColor.textTertiary)
            }
            if !mine { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message-\(m.id)")
    }
}
