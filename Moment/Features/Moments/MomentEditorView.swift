import SwiftUI

/// Scaled live preview of a slide that fits any container.
struct SlidePreview: View {
    let slide: StorySlide
    let theme: StoryTheme
    let format: StoryFormat
    let images: [String: UIImage]
    var showWatermark = true
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / format.size.width, geo.size.height / format.size.height)
            StorySlideView(slide: slide, theme: theme, format: format, image: slide.mediaRef.flatMap { images[$0] }, showWatermark: showWatermark)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: format.size.width * s, height: format.size.height * s)
                .clipShape(RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(format.size.width / format.size.height, contentMode: .fit)
    }
}

/// Make it beautiful, then share it: template, format, export as video / images / a Moment file.
struct MomentEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let storyID: UUID
    @State private var format: StoryFormat = .story
    @State private var page = 0
    @State private var images: [String: UIImage] = [:]
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var showPaywall = false
    @State private var errorText: String?
    @State private var invitePerson: String?
    @State private var showInvite = false
    @State private var editingTitle = false
    @State private var titleDraft = ""

    private var story: MomentStory? { env.stories.story(id: storyID) }

    var body: some View {
        if let story { content(story) } else { EmptyStateView(symbol: "sparkles.rectangle.stack", title: "That Moment is gone", message: "") }
    }

    private func content(_ story: MomentStory) -> some View {
        let template = MomentTemplate.find(story.templateID) ?? MomentTemplate.builtIn[0]
        let theme = StoryTheme.from(template.style)
        return VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(story.slides.enumerated()), id: \.element.id) { i, slide in
                    SlidePreview(slide: slide, theme: theme, format: format, images: images).padding(.horizontal, MSpacing.l).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(maxHeight: .infinity)

            VStack(spacing: MSpacing.m) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        ForEach(MomentTemplate.builtIn) { t in
                            Button { apply(t, to: story) } label: { Text("\(t.emoji) \(t.name.replacingOccurrences(of: "{year}", with: String(Calendar.current.component(.year, from: .now))).replacingOccurrences(of: "{person}", with: story.peopleNames.first ?? "them"))") }
                                .buttonStyle(ChipButtonStyle(prominent: t.id == story.templateID))
                        }
                    }.padding(.horizontal, MSpacing.l)
                }
                Picker("Format", selection: $format) { ForEach(StoryFormat.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, MSpacing.l)
                if exporting {
                    VStack(spacing: 4) { ProgressView(value: exportProgress); Text("Making your video…").font(MFont.caption).foregroundStyle(MColor.textSecondary) }.padding(.horizontal, MSpacing.l)
                } else {
                    HStack(spacing: MSpacing.s) {
                        Menu {
                            if env.flags.isOn(.storyVideoExport) { Button { Task { await exportVideo(story, theme: theme) } } label: { Label("Share as video", systemImage: "film") } }
                            Button { Task { await exportImages(story, theme: theme) } } label: { Label("Share as images", systemImage: "photo.on.rectangle") }
                            Button { Task { await sendPackage(story) } } label: { Label("Send as a Moment (opens in MOMENT)", systemImage: "m.square") }
                        } label: { Text(env.flags.shareCTA).frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("momentShare")
                    }
                    .padding(.horizontal, MSpacing.l)
                }
            }
            .padding(.vertical, MSpacing.m)
            .background(.bar)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { titleDraft = story.title; editingTitle = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { env.stories.delete(story); dismiss() } label: { Label("Delete Moment", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
            }
        }
        .task { images = await env.stories.exporter.loadImages(for: story) }
        .sheet(isPresented: $showShare, onDismiss: { shareItems = []; maybeInvite(story) }) { ShareSheet(items: shareItems) }
        .sheet(isPresented: $showPaywall) { PaywallView(presentedAsSheet: true) }
        .alert("Couldn't export", isPresented: Binding(get: { errorText != nil }, set: { _ in errorText = nil })) { Button("OK") {} } message: { Text(errorText ?? "") }
        .alert("Rename", isPresented: $editingTitle) {
            TextField("Title", text: $titleDraft)
            Button("Save") { story.title = titleDraft.trimmed; if var cover = story.slides.first, cover.kind == .cover { cover.title = story.title; story.slides[0] = cover }; env.storage.save() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(invitePerson.map { "\($0) was there too. Send it to them?" } ?? "", isPresented: $showInvite, titleVisibility: .visible) {
            Button("Send as a Moment") { env.analytics.track(.contextualInviteAccepted); Task { await sendPackage(story) } }
            Button("Not now", role: .cancel) {}
        }
    }

    private func apply(_ t: MomentTemplate, to story: MomentStory) {
        let memories = story.memoryIDs.compactMap { env.storage.memory(id: $0) }
        guard !memories.isEmpty else { return }
        let out = StoryComposer(userName: env.settings.displayName.isBlank ? nil : env.settings.displayName).compose(template: t, memories: memories.map(env.stories.storyMemory), periodLabel: story.kind == .monthRecap || story.kind == .yearRecap ? story.title : nil, person: story.kind == .friendship ? story.peopleNames.first : nil, fallbackTitle: story.title)
        story.templateID = t.id
        story.slides = out.slides
        story.subtitle = out.subtitle
        story.updatedAt = .now
        env.storage.save()
        page = 0
    }

    private func gate() -> Bool {
        guard env.stories.canExport() else { showPaywall = true; return false }
        return true
    }

    private func exportImages(_ story: MomentStory, theme: StoryTheme) async {
        guard gate() else { return }
        exporting = true; defer { exporting = false }
        do {
            let urls = try await env.stories.exporter.exportImages(story, theme: theme, format: format)
            env.stories.noteExport(story, kind: "images")
            shareItems = urls.compactMap { UIImage(contentsOfFile: $0.path()) }
            showShare = true
        } catch { errorText = error.localizedDescription }
    }

    private func exportVideo(_ story: MomentStory, theme: StoryTheme) async {
        guard gate() else { return }
        exporting = true; exportProgress = 0
        defer { exporting = false }
        do {
            let url = try await env.stories.exporter.exportVideo(story, theme: theme, format: format) { exportProgress = $0 }
            env.stories.noteExport(story, kind: "video")
            env.analytics.track(.momentExportedVideo)
            shareItems = [url]
            showShare = true
        } catch { errorText = error.localizedDescription }
    }

    private func sendPackage(_ story: MomentStory) async {
        guard gate() else { return }
        do {
            let url = try await env.stories.package(story)
            env.stories.noteExport(story, kind: "package")
            shareItems = [url]
            showShare = true
        } catch { errorText = error.localizedDescription }
    }

    /// Contextual invitation: never "invite friends" — the person who was there.
    private func maybeInvite(_ story: MomentStory) {
        guard env.flags.isOn(.contextualInvites), invitePerson == nil, let p = story.peopleNames.first, p != env.settings.displayName else { return }
        invitePerson = p
        env.analytics.track(.contextualInviteShown)
        showInvite = true
    }
}
