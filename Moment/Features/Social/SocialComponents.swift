import SwiftUI

/// Loads a `MediaRef` through the social service (local first, then backend) with a soft placeholder.
struct SocialImage: View {
    @Environment(AppEnvironment.self) private var env
    let ref: MediaRef?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        // The rectangle takes whatever frame the caller proposes; the image is an overlay clipped to it.
        Rectangle().fill(MColor.fill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else if ref != nil {
                    ProgressView().tint(MColor.textTertiary)
                } else {
                    Image(systemName: "photo").foregroundStyle(MColor.textTertiary)
                }
            }
            .clipped()
        .task(id: ref) { image = await env.social.image(for: ref) }
    }
}

/// Overlapping avatars: "Rahul, Sarah + you".
struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 28
    var max: Int = 4
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(max).enumerated()), id: \.offset) { _, n in
                PersonAvatar(name: n, size: size).overlay(Circle().strokeBorder(MColor.background, lineWidth: 2))
            }
            if names.count > max {
                Text("+\(names.count - max)").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(MColor.textPrimary)
                    .frame(width: size, height: size).background(MColor.surfaceSecondary, in: Circle()).overlay(Circle().strokeBorder(MColor.background, lineWidth: 2))
            }
        }
        .accessibilityLabel(names.joined(separator: ", "))
    }
}

/// The reaction row under a Moment or contribution. One tap toggles; long-press opens the full set.
struct ReactionBar: View {
    @Environment(AppEnvironment.self) private var env
    let momentID: String
    var contributionID: String? = nil
    let counts: [String: Int]
    var compact = false
    var onReact: ((ReactionKind) -> Void)? = nil
    @State private var showAll = false

    private var shown: [ReactionKind] {
        let used = ReactionKind.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
        let base = used.isEmpty ? [ReactionKind.core] : used
        return compact ? Array(base.prefix(3)) : base
    }

    var body: some View {
        HStack(spacing: MSpacing.s) {
            ForEach(shown, id: \.self) { kind in
                let mine = env.social.myReaction(momentID: momentID, contributionID: contributionID) == kind
                Button {
                    if !mine { Haptics.saved(); onReact?(kind) }
                    Task { await env.social.react(momentID: momentID, contributionID: contributionID, kind: kind) }
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.emoji)
                        if let c = counts[kind.rawValue], c > 0 { Text("\(c)").font(MFont.caption).monospacedDigit() }
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: mine))
                .accessibilityLabel("\(kind.label)\(mine ? ", selected" : "")")
                .accessibilityIdentifier("react-\(kind.rawValue)")
            }
            Button { showAll = true } label: { Image(systemName: "face.smiling").font(.subheadline) }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("More reactions")
        }
        .sheet(isPresented: $showAll) {
            ReactionPicker(momentID: momentID, contributionID: contributionID, onReact: onReact)
                .presentationDetents([.height(220)])
        }
    }
}

struct ReactionPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    var contributionID: String?
    var onReact: ((ReactionKind) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("React").font(MFont.headline).padding(.top, MSpacing.l)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: MSpacing.m) {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    Button {
                        Haptics.saved(); onReact?(kind)
                        Task { await env.social.react(momentID: momentID, contributionID: contributionID, kind: kind) }
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text(kind.emoji).font(.title2)
                            Text(kind.label).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, MSpacing.s)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, MSpacing.l)
        .presentationDragIndicator(.visible)
    }
}

/// iCloud not signed in / offline / restricted banner.
struct AccountBanner: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        if env.social.accountStatus != .available {
            HStack(spacing: MSpacing.m) {
                Image(systemName: "icloud.slash").foregroundStyle(MColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MFont.headline)
                    Text(message).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Button("Retry") { Task { await env.social.start() } }.buttonStyle(ChipButtonStyle())
            }
            .padding(.vertical, MSpacing.m)
            .overlay(Rectangle().fill(MColor.separator).frame(height: 0.5), alignment: .bottom)
            .accessibilityIdentifier("accountBanner")
        }
    }
    private var title: String {
        switch env.social.accountStatus {
        case .noAccount: "Sign in to iCloud"
        case .offline: "You're offline"
        case .restricted: "iCloud is restricted"
        default: "Connecting…"
        }
    }
    private var message: String {
        switch env.social.accountStatus {
        case .noAccount: "Publishing and following use your iCloud account. Settings › Apple Account › iCloud."
        case .offline: "Everything you've unlocked is still here. Uploads resume when you're back."
        case .restricted: "Parental controls or MDM are blocking iCloud for this app."
        default: "Checking your account."
        }
    }
}

struct UploadBanner: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        if env.social.queue.pendingCount > 0 {
            HStack(spacing: MSpacing.m) {
                if env.social.queue.failedCount > 0 && env.social.queue.failedCount == env.social.queue.pendingCount {
                    Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90").foregroundStyle(MColor.danger)
                    Text("\(env.social.queue.failedCount) uploads need a retry").font(MFont.subheadline)
                    Spacer()
                    Button("Retry") { env.social.queue.retryFailed() }.buttonStyle(ChipButtonStyle(prominent: true))
                } else {
                    ProgressView().tint(MColor.accent)
                    Text("Uploading \(env.social.queue.pendingCount)…").font(MFont.subheadline)
                    Spacer()
                }
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m)
            .background(MColor.surface, in: Capsule())
            .accessibilityIdentifier("uploadBanner")
        }
    }
}

struct SocialErrorAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(get: { env.social.lastError != nil }, set: { _ in env.social.clearError() })) {
            Button("Try again") { Task { await env.social.refreshAll() } }
            Button("OK", role: .cancel) {}
        } message: { Text(env.social.lastError ?? "") }
    }
}

extension SocialService {
    func clearError() { lastError = nil }
}

/// Report a person or a post. Reports are signed records the creator's side never sees;
/// on the decentralised network they reach whoever runs the relay you're on.
struct ReportSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var userID: String? = nil
    var setID: String? = nil
    @State private var reason: UserReport.Reason = .spam
    @State private var details = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What's wrong") {
                    Picker("Reason", selection: $reason) { ForEach(UserReport.Reason.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                }
                Section("Anything to add") {
                    TextField("Optional", text: $details, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("reportDetails")
                }
                Section {
                    Button {
                        Task {
                            await env.social.report(userID: userID, momentID: setID, reason: reason, details: details)
                            sent = true
                            try? await Task.sleep(for: .seconds(1)); dismiss()
                        }
                    } label: { Text(sent ? "Sent" : "Send report").frame(maxWidth: .infinity) }
                        .disabled(sent).accessibilityIdentifier("sendReport")
                    if let userID {
                        Button("Block them too", role: .destructive) { Task { await env.social.block(userID); dismiss() } }
                    }
                } footer: {
                    Text("Blocking hides them from you everywhere, immediately. Reports are read by whoever runs the relay; we hold nothing centrally.")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
