import SwiftUI

/// Export a shared Moment as a vertical video or image set (reuses the story renderer).
struct MomentExportSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let moment: SocialMoment
    @State private var format: StoryFormat = .story
    @State private var working = false
    @State private var progress = 0.0
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                Text("Exports include every side with the person's name. No music, no watermark clutter — just \"Made with MOMENT\" on the last frame.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Picker("Format", selection: $format) { ForEach(StoryFormat.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                if working { ProgressView(value: progress).tint(MColor.accent) }
                Button { Task { await export(video: true) } } label: { Label("Export video", systemImage: "film").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).disabled(working)
                Button { Task { await export(video: false) } } label: { Label("Export images", systemImage: "photo.stack").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle()).disabled(working)
                Spacer()
            }
            .padding(MSpacing.l)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        }
        .presentationDetents([.medium])
    }

    private func export(video: Bool) async {
        working = true; defer { working = false }
        let story = await buildStory()
        let theme = StoryTheme.from(.cinematic)
        do {
            if video {
                let url = try await env.stories.exporter.exportVideo(story, theme: theme, format: format) { progress = $0 }
                env.analytics.track(.momentExportedVideo)
                shareItems = [url]
            } else {
                shareItems = try await env.stories.exporter.exportImages(story, theme: theme, format: format)
            }
            showShare = true
        } catch { env.social.lastError = error.localizedDescription }
    }

    /// A transient story object (not persisted) built from the shared Moment's real contributions.
    private func buildStory() async -> MomentStory {
        var slides: [StorySlide] = [StorySlide(kind: .cover, title: moment.title, body: "\(moment.dateLabel)\(moment.coarsePlace.map { " · \($0)" } ?? "")", mediaRef: await localRef(moment.coverRef))]
        for c in env.social.allContributions(moment.id).prefix(10) {
            switch c.kind {
            case .photo, .video: slides.append(StorySlide(kind: .side, title: c.caption, body: c.authorName, mediaRef: await localRef(c.media), date: c.originalTimestamp ?? c.createdAt))
            case .text: slides.append(StorySlide(kind: .quote, title: c.caption, body: c.authorName))
            case .voice: break
            }
        }
        slides.append(StorySlide(kind: .closing, title: moment.memberNames.count > 1 ? "\(moment.memberNames.count) people were there." : "Worth remembering.", body: "Made with MOMENT"))
        return MomentStory(title: moment.title, subtitle: "\(moment.contributionCount) sides", kind: .custom, templateID: "drop.night", slides: slides, peopleNames: moment.memberNames)
    }

    private func localRef(_ ref: MediaRef?) async -> String? {
        guard let ref else { return nil }
        if let l = ref.localRef { return l }
        guard let img = await env.social.image(for: ref), let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        return try? await env.media.store(data, extension: "jpg")
    }
}

/// Owner controls: title, description, visibility, permissions.
struct EditMomentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var draft: SocialMoment?

    var body: some View {
        Form {
            if draft != nil {
                let b = Binding(get: { draft! }, set: { draft = $0 })
                Section("Moment") {
                    TextField("Title", text: b.title).accessibilityIdentifier("editTitle")
                    TextField("Description", text: b.description, axis: .vertical)
                    TextField("Place", text: Binding(get: { b.wrappedValue.locationName ?? "" }, set: { draft?.locationName = $0.isBlank ? nil : $0; draft?.coarsePlace = $0.isBlank ? nil : SocialService.coarse($0) }))
                }
                Section("Who can see it") {
                    Picker("Visibility", selection: b.visibility) { ForEach(MomentVisibility.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) } }
                    Text(b.wrappedValue.visibility.explanation).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Section("Permissions") {
                    Toggle("People in it can add", isOn: b.allowsContributions)
                    Toggle("Allow resharing", isOn: b.allowsReshare)
                    Toggle("Allow downloads", isOn: b.allowsDownload)
                    Toggle("Happening now (LIVE)", isOn: b.isLive)
                }
            }
        }
        .navigationTitle("Edit Moment")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { if let d = draft, await env.social.update(d) { env.toast("Saved."); dismiss() } } }.accessibilityIdentifier("saveMoment") } }
        .onAppear { draft = env.social.moments[momentID] }
    }
}

/// Everyone in the Moment, with what they added. Owner can remove people.
struct MembersView: View {
    @Environment(AppEnvironment.self) private var env
    let momentID: String
    var body: some View {
        List {
            if let m = env.social.moments[momentID] {
                ForEach(Array(zip(m.memberIDs, m.memberNames)), id: \.0) { id, name in
                    NavigationLink(value: SocialRoute.profile(id)) {
                        HStack(spacing: MSpacing.m) {
                            PersonAvatar(name: name, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id == env.social.myID ? "You" : name).font(MFont.headline)
                                let n = env.social.allContributions(m.id).filter { $0.authorID == id }.count
                                Text(id == m.creatorID ? "Created it · \(n) added" : "\(n) added").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Who was there")
    }
}

/// Report a user, Moment, contribution or comment. Goes to the backend report queue.
struct ReportSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var momentID: String? = nil
    var contributionID: String? = nil
    var commentID: String? = nil
    var userID: String? = nil
    @State private var reason: UserReport.Reason = .spam
    @State private var details = ""
    @State private var alsoBlock = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Why?") { Picker("Reason", selection: $reason) { ForEach(UserReport.Reason.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.inline).labelsHidden() }
                Section("Details (optional)") { TextField("What happened?", text: $details, axis: .vertical).lineLimit(2...5) }
                if userID != nil, userID != env.social.myID { Section { Toggle("Also block this person", isOn: $alsoBlock) } }
                Section { Text("Reports are reviewed. The person isn't told who reported them.").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            let ok = await env.social.report(userID: userID, momentID: momentID, contributionID: contributionID, commentID: commentID, reason: reason, details: details)
                            if alsoBlock, let userID { await env.social.block(userID) }
                            if ok { env.toast("Reported. Thank you.") }
                            dismiss()
                        }
                    }.accessibilityIdentifier("sendReport")
                }
            }
        }
    }
}
