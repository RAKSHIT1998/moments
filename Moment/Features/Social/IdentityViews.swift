import SwiftUI
import UniformTypeIdentifiers

/// Your key: the MOMENT ID, the recovery phrase (shown once, saved by you), backup and restore.
struct IdentityView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var phrase: [String] = []
    @State private var confirmed = false
    @State private var backup: BackupFile?
    @State private var showImport = false
    @State private var importPhrase = ""
    @State private var pendingImport: Data?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Your MOMENT ID").sectionLabel()
                    Text(env.identity.momentID).font(.system(.title2, design: .monospaced, weight: .semibold)).textSelection(.enabled).accessibilityIdentifier("momentID")
                    Text("A fingerprint of a key that lives only in this iPhone's Keychain. Everything you create is signed with it, so people can tell it's really yours — without any server.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    HStack(spacing: MSpacing.s) {
                        Button { UIPasteboard.general.string = env.identity.momentID; env.toast("Copied.") } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(ChipButtonStyle())
                        ShareLink(item: "Add me on MOMENT — \(env.identity.momentID)") { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Recovery phrase") {
                if phrase.isEmpty {
                    Text("Generate a 12-word phrase, write it down, and you can bring this identity to a new phone. We never see it.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    Button("Generate recovery phrase") { phrase = IdentityService.generateRecoveryPhrase(); Haptics.saved() }.accessibilityIdentifier("generatePhrase")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(phrase.enumerated()), id: \.offset) { i, w in
                            HStack(spacing: 4) { Text("\(i + 1)").font(.caption2).foregroundStyle(MColor.textTertiary).frame(width: 16, alignment: .trailing); Text(w).font(.system(.callout, design: .monospaced)) }
                                .padding(.vertical, 6).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(MColor.fill, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .accessibilityIdentifier("recoveryPhrase")
                    Toggle("I've written these 12 words down", isOn: $confirmed).tint(MColor.accent)
                    Button("Create encrypted backup") {
                        if let data = try? env.identity.exportBackup(phrase: phrase) { backup = BackupFile(data: data); Haptics.completed() }
                    }
                    .disabled(!confirmed)
                    if let backup {
                        ShareLink(item: backup, preview: SharePreview("MOMENT identity backup")) { Label("Save backup file", systemImage: "arrow.down.doc") }
                        Text("The file is useless without the phrase. Keep them apart.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                    }
                    Button("Generate a different phrase", role: .destructive) { phrase = IdentityService.generateRecoveryPhrase(); confirmed = false; backup = nil }
                }
            }
            Section("Restore on this phone") {
                Text("Have a backup from another phone? Import it with its phrase. This replaces the identity on this device.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Button("Import backup…") { showImport = true }
            }
            if let message { Section { Text(message).font(MFont.footnote) } }
        }
        .navigationTitle("Identity & recovery")
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource(), let data = try? Data(contentsOf: url) { pendingImport = data; url.stopAccessingSecurityScopedResource() }
        }
        .alert("Recovery phrase", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            TextField("12 words, separated by spaces", text: $importPhrase)
            Button("Restore") {
                guard let data = pendingImport else { return }
                let words = importPhrase.lowercased().split(separator: " ").map(String.init)
                do { let id = try env.identity.importBackup(data, phrase: words); message = "Restored \(id). Restart the app to sign with it."; Haptics.completed() }
                catch { message = error.localizedDescription }
                importPhrase = ""; pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text("Type the 12 words that go with this backup.") }
    }

    struct BackupFile: Transferable {
        let data: Data
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .json) { $0.data }.suggestedFileName("moment-identity-backup.json")
        }
    }
}

/// Onboarding step: your key exists — here's your ID, and the one-time chance to save a phrase.
struct IdentityOnboardingStep: View {
    @Environment(AppEnvironment.self) private var env
    var onDone: () -> Void
    @State private var phrase = IdentityService.generateRecoveryPhrase()
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            Spacer()
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("Your key is ready.").font(MFont.hero).tracking(-0.8)
                Text("No password, no email. A key on this iPhone signs everything you make. This is its ID:").font(MFont.body).foregroundStyle(MColor.textSecondary)
                Text(env.identity.momentID).font(.system(.title3, design: .monospaced, weight: .semibold)).padding(MSpacing.m).frame(maxWidth: .infinity).background(MColor.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).accessibilityIdentifier("onboardingMomentID")
            }
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("Recovery phrase").sectionLabel()
                Text(phrase.joined(separator: "  ")).font(.system(.callout, design: .monospaced)).lineSpacing(6).padding(MSpacing.m).frame(maxWidth: .infinity, alignment: .leading).background(MColor.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).textSelection(.enabled)
                Text("Write it down. It's the only way to move your identity to a new phone — we can't recover it for you.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Toggle("I've saved it", isOn: $saved).tint(MColor.accent).accessibilityIdentifier("savedPhrase")
            }
            Spacer()
            Button(saved ? "Continue" : "Skip for now — I'll do it in Settings") { onDone() }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("identityContinue")
        }
        .padding(.horizontal, MSpacing.xxl).padding(.bottom, MSpacing.xl)
    }
}

/// Invite friends: the growth loop, without a server. Your ID + a link + a card, and the honest
/// numbers of what your invites turned into.
struct InviteFriendsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var qr: UIImage?

    private var link: URL { URL(string: "https://moment.app/u/\(env.identity.momentID.replacingOccurrences(of: "MMT-", with: "").lowercased())")! }
    private var text: String { "I'm on MOMENT — one Moment, everyone's story. Add me: \(env.identity.momentID)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invite your people").displayStyle()
                    Text("MOMENT is only good with the people you actually see. Every Moment you share is an invite; this is the direct one.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                HStack {
                    Spacer()
                    VStack(spacing: MSpacing.s) {
                        ZStack { RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).fill(.white).frame(width: 220, height: 220).shadow(color: .black.opacity(0.12), radius: 16, y: 8); if let qr { Image(uiImage: qr).interpolation(.none).resizable().frame(width: 190, height: 190) } }
                        Text(env.identity.momentID).font(.system(.callout, design: .monospaced, weight: .semibold))
                    }
                    Spacer()
                }
                VStack(spacing: MSpacing.s) {
                    ShareLink(item: link, subject: Text("MOMENT"), message: Text(text)) { Label("Share invite link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("shareInvite")
                        .simultaneousGesture(TapGesture().onEnded { env.analytics.track(.inviteSent, category: "profile") })
                    Button { UIPasteboard.general.string = text; env.toast("Copied."); env.analytics.track(.inviteSent, category: "copy") } label: { Text("Copy message").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle())
                }
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Your loop").sectionLabel()
                    HStack(spacing: MSpacing.s) {
                        StatTile(value: "\(env.analytics.count(.inviteSent))", label: "invites sent", symbol: "paperplane")
                        StatTile(value: "\(env.analytics.sharedMomentsCreated)", label: "Moments shared", symbol: "person.2")
                        StatTile(value: "\(env.social.graph.followers.count)", label: "people following you", symbol: "person.crop.circle.badge.plus")
                    }
                    Text("Counted on this phone only. Nothing about your friends is uploaded.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("What spreads MOMENT").sectionLabel()
                    loopRow("Start a Moment at anything with more than two people", "The invite link and QR are the product. Every guest becomes a member.")
                    loopRow("Put the QR on the table at your venue", "Claim the place; regulars and their friends fill the page.")
                    loopRow("Share a Moment Card", "One image with the title, the people and the link — made for group chats.")
                }
            }
            .padding(MSpacing.page).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle("Invite").navigationBarTitleDisplayMode(.inline)
        .task { qr = MomentQR.make(link.absoluteString, tint: .black) }
    }

    private func loopRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: MSpacing.m) {
            Circle().fill(MColor.textPrimary).frame(width: 6, height: 6).padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
        }
    }
}
