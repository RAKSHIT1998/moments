import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section("Your Moment") {
                NavigationLink(value: Route.homeSettings) { Label("Home", systemImage: "house") }
                NavigationLink(value: Route.stats) { Label("Your memory", systemImage: "chart.bar") }
                NavigationLink(value: Route.subscription) {
                    HStack { Label("MOMENT Pro", systemImage: "star"); Spacer(); Text(env.subscriptions.isPro ? "Active" : "Free").foregroundStyle(MColor.textSecondary) }
                }
            }
            Section("Intelligence") {
                NavigationLink(value: Route.aiSettings) { Label("AI processing", systemImage: "cpu") }
                Text(settings.useCloudAI ? "Cloud AI is on — captures are sent to your provider." : "Everything is understood on this iPhone.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Privacy") {
                NavigationLink(value: Route.privacy) { Label("Privacy Center", systemImage: "hand.raised") }
                Toggle(isOn: Binding(get: { settings.requireBiometrics }, set: { on in Task { if on { _ = await env.lock.enableLock() } else { _ = await env.lock.disableLock() } } })) {
                    Label("Lock MOMENT with \(env.lock.biometrics.label)", systemImage: "faceid")
                }
                .disabled(env.lock.biometrics.availability == .unavailable)
                NavigationLink(value: Route.dataSettings) { Label("Export, media & delete", systemImage: "externaldrive") }
            }
            Section("Notifications") {
                NavigationLink(value: Route.notificationSettings) { Label("Reminders", systemImage: "bell") }
            }
            Section("Identity") {
                NavigationLink(value: SocialRoute.identity) { Label("Identity & recovery phrase", systemImage: "key") }
                NavigationLink(value: SocialRoute.invite) { Label("Invite friends", systemImage: "person.badge.plus") }
            }
            Section("Setup") {
                Button { settings.setupCompleted = false } label: { Label("Run setup again", systemImage: "checklist") }
                #if DEBUG
                Toggle(isOn: Binding(get: { settings.demoMode }, set: { on in Task { if on { await env.enableDemoMode() } else { await env.disableDemoMode() } } })) {
                    Label("Sample data (development)", systemImage: "sparkles")
                }
                Text("Fictional people and Moments on an in-process backend. Turning it off deletes them and returns to iCloud.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                #endif
            }
            Section("Connections") {
                Toggle(isOn: Binding(get: { settings.calendarConnected }, set: { on in Task { if on { settings.calendarConnected = await env.calendar.connect() } else { settings.calendarConnected = false } } })) {
                    Label("Calendar", systemImage: "calendar")
                }
                Text("Optional. Used as context only; MOMENT never adds events without asking.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                HStack { Label("Contacts", systemImage: "person.crop.circle"); Spacer(); Text(env.contacts.isAuthorized ? "Link per person" : "Not connected").foregroundStyle(MColor.textSecondary) }
                Text("MOMENT never imports your address book. Link a person from their profile.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) { Text("Automatic").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
                Text(appearance == "system" ? "Follows your iPhone's Light/Dark setting, including schedules. Text, cards and colours adapt automatically." : "Fixed. Choose Automatic to follow your iPhone again.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("About") {
                NavigationLink(value: Route.about) { Label("About MOMENT", systemImage: "info.circle") }
                if let url = AppConfig.supportURL { Link(destination: url) { Label("Support & feedback", systemImage: "questionmark.circle") } }
                if let url = AppConfig.privacyPolicyURL { Link(destination: url) { Label("Privacy Policy", systemImage: "hand.raised") } }
                if let url = AppConfig.termsURL { Link(destination: url) { Label("Terms of Use", systemImage: "doc.text") } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Settings")
    }
}

/// Where the data is, where it's processed, what leaves the device. All in one place.
struct PrivacyCenterView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Your memories belong to you.").font(MFont.title).tracking(-0.3)
                    Text("Here's exactly where they live and what leaves this iPhone.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }.padding(.vertical, 6)
            }
            Section {
                row("Private memory: stored on this iPhone", "Memories, people, plans and media. Encrypted with iOS Data Protection; media is additionally AES-GCM encrypted. Never synced.", "iphone", ok: true)
                row("No MOMENT servers. No account with us.", "There is no MOMENT backend and no sign-up: you are your iCloud identity. Moments you make live in your own iCloud; inviting someone shares that one Moment with them, nothing else. We never see, store or sell any of it.", "server.rack", ok: true)
                row("What's public is only what you chose", "Public Moments and \"show me on Nearby\" posts are visible to everyone by your choice — and only the venue, never your phone's location. Everything else is private or invite-only.", "globe", ok: true)
                row("Photos are stripped before they leave", "Compressed and cleared of GPS, device and lens metadata. Only the capture time is kept, for the timeline.", "photo", ok: true)
                row("Processed on this iPhone", "Text recognition, speech, understanding and search run locally.", "cpu", ok: true)
                row(env.settings.useCloudAI ? "Sent to cloud AI: only what you capture, when you capture it" : "Sent to cloud AI: nothing", env.settings.useCloudAI ? "Cloud AI is ON. Each capture is sent to the AI provider using your own key. Your memory database is never uploaded." : "Cloud AI is off. Nothing you capture leaves this device.", "cloud", ok: !env.settings.useCloudAI)
                row("Shared with apps: nothing", "The widget reads a short snapshot inside MOMENT's own app group. No third-party SDKs. No ad networks.", "square.grid.2x2", ok: true)
                row(env.settings.requireBiometrics ? "iPhone search: off" : "iPhone search: titles only", env.settings.requireBiometrics ? "Because MOMENT is locked, nothing is indexed for Spotlight." : "Memory titles are indexed so Spotlight can find them. Turn on the lock to disable.", "magnifyingglass", ok: true)
                row("Analytics: nothing is sent", "MOMENT has no analytics service and no third-party SDKs. Optional usage counts stay on this iPhone.", "chart.bar", ok: true)
            }
            Section("Controls") {
                NavigationLink(value: SocialRoute.safety) { Text("Privacy & safety (shared Moments)") }
                NavigationLink(value: Route.aiSettings) { Text("Cloud AI") }
                NavigationLink(value: Route.dataSettings) { Text("Export, clear media, delete everything") }
                Button("Clear search history") { env.settings.clearSearchHistory() }
            }
        }
        .navigationTitle("Privacy Center")
    }
    private func row(_ title: String, _ detail: String, _ symbol: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: MSpacing.m) {
            Image(systemName: symbol).foregroundStyle(ok ? MColor.success : MColor.warning).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(MFont.headline); Text(detail).font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
        }.padding(.vertical, 4)
    }
}

struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var apiKey = ""
    @State private var hasKey = RemoteIntelligenceProvider.hasKey
    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Use Cloud AI", isOn: $settings.useCloudAI)
            } footer: {
                Text("Cloud AI can improve understanding of messy screenshots and long voice notes, but requires sending the selected content to our AI provider (Anthropic). Off by default. Search and the rest of your memory always stay on this iPhone.")
            }
            if settings.useCloudAI {
                Section("Your API key") {
                    SecureField(hasKey ? "Key saved in Keychain" : "Paste your key", text: $apiKey)
                    Button("Save key") { try? Keychain.setString(apiKey.trimmed, for: RemoteIntelligenceProvider.keychainKey); hasKey = true; apiKey = "" }.disabled(apiKey.isBlank)
                    if hasKey { Button("Remove key", role: .destructive) { Keychain.delete(RemoteIntelligenceProvider.keychainKey); hasKey = false } }
                    Text("Model: \(RemoteIntelligenceProvider.model). Stored only in this device's Keychain.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
            }
            Section("On-device understanding") {
                Text("MOMENT reads text with Vision, transcribes with Speech, and understands people, plans, promises and gift ideas with an on-device engine built on NaturalLanguage. It never guesses: uncertain items are marked “Needs review”.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
        .navigationTitle("AI")
    }
}

struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status: String = ""
    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Notifications", isOn: $settings.notificationsEnabled)
                Stepper("Up to \(settings.dailyNotificationBudget) a day", value: $settings.dailyNotificationBudget, in: 0...5)
                if !status.isEmpty { Text("System permission: \(status)").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                if status == "Not asked yet" { Button("Allow notifications") { Task { _ = await env.notifications.requestAuthorization(); await load() } } }
            } footer: {
                Text("Only genuinely useful ones — a birthday coming up with a gift idea saved, a promise going stale, a plan whose time is near. Never “come back to MOMENT”.")
            }
            Section("Shared Moments") {
                Toggle("When people add to a Moment I'm in", isOn: $settings.socialNotifications)
                Text("One alert per Moment that grew — who and how many, never the photos.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Privacy") {
                Toggle("Show details in notifications", isOn: $settings.notificationDetails)
                Text("Off by default: notifications only say that something matters. Turn on to see the name and what it's about, e.g. “Sarah's birthday is in 7 days”.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Toggle("Show content in Lock Screen widget", isOn: $settings.lockScreenWidgetAllowed)
                Text("Off by default so nothing personal shows before you unlock.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
        .navigationTitle("Notifications")
        .task { await load() }
        .onChange(of: settings.notificationsEnabled) { _, _ in Task { await env.surface.refresh() } }
        .onChange(of: settings.dailyNotificationBudget) { _, _ in Task { await env.surface.refresh() } }
        .onChange(of: settings.notificationDetails) { _, _ in Task { await env.surface.refresh() } }
        .onChange(of: settings.lockScreenWidgetAllowed) { _, _ in Task { await env.surface.refresh(scheduleNotifications: false) } }
    }
    private func load() async {
        switch await env.notifications.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: status = "Allowed"
        case .denied: status = "Denied in iOS Settings"
        case .notDetermined: status = "Not asked yet"
        @unknown default: status = ""
        }
    }
}

struct DataSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showClearMediaConfirm = false
    @State private var mediaSize: Int64 = 0
    @State private var deleted = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Export") {
                ForEach(ExportService.Format.allCases) { f in
                    Button("Export as \(f.label)") { export(f) }
                }
                Text("You own your data. \(env.storage.memoryCount) memories.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Media") {
                Button("Clear imported media (\(ByteCountFormatter.string(fromByteCount: mediaSize, countStyle: .file)))") { showClearMediaConfirm = true }
                Text("Removes stored screenshots, audio and files. Text memories stay.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            #if DEBUG
            Section("Demo (DEBUG)") {
                if env.settings.demoLoaded { Button("Remove demo data") { Task { await DemoData.remove(from: env) } } }
                else { Button("Load demo data") { Task { await DemoData.seedAsync(into: env) } } }
            }
            #endif
            Section {
                Button("Delete All Data", role: .destructive) { showDeleteConfirm = true }.accessibilityIdentifier("deleteAllData")
            } footer: {
                Text("This permanently deletes your MOMENT memories and stored media from this device. There is no hidden copy.")
            }
        }
        .navigationTitle("Data")
        .task { mediaSize = await env.lifecycle.mediaSize() }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { _ in exportError = nil })) { Button("OK") {} } message: { Text(exportError ?? "") }
        .confirmationDialog("Delete everything?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete All Data", role: .destructive) { Task { try? await env.lifecycle.deleteEverything(); deleted = true; await env.surface.refresh(scheduleNotifications: false) } }
        } message: { Text("This cannot be undone. Export first if you want a copy.") }
        .confirmationDialog("Clear imported media?", isPresented: $showClearMediaConfirm, titleVisibility: .visible) {
            Button("Clear media", role: .destructive) { Task { await env.lifecycle.clearImportedMedia(); mediaSize = await env.lifecycle.mediaSize() } }
        }
        .alert("All data deleted", isPresented: $deleted) { Button("OK") {} }
    }

    private func export(_ f: ExportService.Format) {
        do { exportURL = try ExportService(storage: env.storage).export(f) } catch { exportError = error.localizedDescription }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AboutView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Wordmark(size: 26)
                    Text("Be there. Remember it.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }.padding(.vertical, 8)
            }
            Section("Your numbers") {
                LabeledRow(label: "Shared Moments you started", value: "\(env.analytics.sharedMomentsCreated)")
                LabeledRow(label: "Moments you joined", value: "\(env.analytics.count(.momentJoined))")
                LabeledRow(label: "Memories saved", value: "\(env.storage.memoryCount)")
                LabeledRow(label: "Useful memories resurfaced", value: "\(env.storage.profile().usefulMemoriesResurfaced)")
                Text("The number MOMENT cares about: experiences you kept together with the people who were there.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Analytics") {
                @Bindable var settings = env.settings
                Toggle("Keep usage counts on this iPhone", isOn: $settings.analyticsEnabled)
                Text("Counts events like “capture completed” locally so you can see them here. Nothing is sent anywhere, and never your content.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
        .navigationTitle("About")
    }
}
