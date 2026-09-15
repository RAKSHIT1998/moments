import SwiftUI
import PhotosUI

/// The shared Moment is a product of its own: full-screen, immersive, ends with
/// "You were there too. Add your side." and "Make your own".
struct MomentViewerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let storyID: UUID
    @State private var page = 0
    @State private var images: [String: UIImage] = [:]
    @State private var showAddSide = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var remixedID: UUID?
    @State private var showEditor = false

    private var story: MomentStory? { env.stories.story(id: storyID) }

    var body: some View {
        if let story { content(story) } else { EmptyStateView(symbol: "sparkles.rectangle.stack", title: "That Moment is gone", message: "") }
    }

    private func content(_ story: MomentStory) -> some View {
        let template = MomentTemplate.find(story.templateID) ?? MomentTemplate.builtIn[0]
        let theme = StoryTheme.from(template.style)
        let last = story.slides.count // index of the end card
        return ZStack {
            theme.background.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(story.slides.enumerated()), id: \.element.id) { i, slide in
                    SlidePreview(slide: slide, theme: theme, format: .story, images: images, showWatermark: false).padding(.horizontal, MSpacing.m).tag(i)
                }
                endCard(story, theme: theme).tag(last)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(story.title).font(MFont.headline).foregroundStyle(theme.foreground)
                        if let a = story.originAuthor { Text("From \(a)").font(MFont.caption).foregroundStyle(theme.muted) }
                        else if let r = story.remixedFrom { Text("Remixed from \(r)").font(MFont.caption).foregroundStyle(theme.muted) }
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(theme.foreground).frame(width: 36, height: 36).background(theme.foreground.opacity(0.12), in: Circle()) }.accessibilityLabel("Close")
                }
                .padding(.horizontal, MSpacing.l)
                Spacer()
                if page < last { reactions(story, theme: theme) }
            }
            .padding(.vertical, MSpacing.s)
        }
        .task { images = await env.stories.exporter.loadImages(for: story) }
        .sheet(isPresented: $showAddSide) { AddSideSheet(story: story) }
        .sheet(isPresented: $showShare, onDismiss: { shareItems = [] }) { ShareSheet(items: shareItems) }
        .navigationDestination(isPresented: $showEditor) { if let id = remixedID { MomentEditorView(storyID: id) } }
    }

    /// Reactions native to memories — not likes.
    private func reactions(_ story: MomentStory, theme: StoryTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MSpacing.s) {
                ForEach(MemoryReaction.allCases, id: \.self) { r in
                    let mine = story.reactions.contains { $0.authorName == env.stories.authorName && $0.reaction == r }
                    let count = story.reactions.filter { $0.reaction == r }.count
                    Button { env.stories.react(story, r); Haptics.selection() } label: {
                        HStack(spacing: 4) { Text(r.emoji); Text(count > 0 ? "\(count)" : "").font(.caption.weight(.semibold)) }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(mine ? theme.accent.opacity(0.3) : theme.foreground.opacity(0.1), in: Capsule())
                            .foregroundStyle(theme.foreground)
                    }
                    .accessibilityLabel(r.rawValue + (count > 0 ? ", \(count)" : ""))
                }
            }.padding(.horizontal, MSpacing.l)
        }
    }

    /// The viral loop lives here.
    private func endCard(_ story: MomentStory, theme: StoryTheme) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Spacer()
            if story.isReceived {
                Text("You were there too.").font(.system(size: 34, weight: .bold)).tracking(-0.8).foregroundStyle(theme.foreground)
                Text("Add your side of the memory — a photo, a line, your version of what happened. \(story.originAuthor ?? "They") will see it when you send it back.").font(MFont.body).foregroundStyle(theme.muted)
                Button("Add your side") { showAddSide = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("addSide")
                if story.contributions.contains(where: \.isMine) || story.reactions.contains(where: { $0.authorName == env.stories.authorName }) {
                    Button("Send it back to \(story.originAuthor ?? "them")") { Task { await sendBack(story) } }.buttonStyle(SecondaryButtonStyle())
                }
                if env.flags.isOn(.remix) {
                    Divider().overlay(theme.muted.opacity(0.3))
                    Text("Make your own").font(MFont.title).tracking(-0.3).foregroundStyle(theme.foreground)
                    Text("Same template, your memories.").font(MFont.subheadline).foregroundStyle(theme.muted)
                    Button("Make yours") { remix(story) }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("makeYours")
                }
            } else {
                Text(story.contributions.isEmpty ? "That's the Moment." : "\(story.contributions.count) side\(story.contributions.count == 1 ? "" : "s") added.").font(.system(size: 34, weight: .bold)).tracking(-0.8).foregroundStyle(theme.foreground)
                if !story.peopleNames.isEmpty { Text("\(story.peopleNames.prefix(3).joined(separator: ", ")) \(story.peopleNames.count == 1 ? "was" : "were") there too. Send it so they can add their side.").font(MFont.body).foregroundStyle(theme.muted) }
                NavigationLink(value: Route.momentEditor(story.id)) { Text(env.flags.shareCTA).frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 6) { Image(systemName: "m.square.fill").foregroundStyle(theme.accent); Text("Made with MOMENT").font(MFont.caption).foregroundStyle(theme.muted) }
            Spacer()
        }
        .padding(MSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendBack(_ story: MomentStory) async {
        if let url = try? await env.stories.package(story) { shareItems = [url]; showShare = true; env.analytics.track(.momentShared, category: "sendBack") }
    }

    private func remix(_ story: MomentStory) {
        guard let s = env.stories.remix(story) else { env.toast("Capture a few memories first, then make yours."); return }
        remixedID = s.id
        showEditor = true
    }
}

/// A photo and/or a line. Nothing else asked.
struct AddSideSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let story: MomentStory
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("Your side").displayStyle()
                Text("How do you remember it?").font(MFont.body).foregroundStyle(MColor.textSecondary)
                TextEditor(text: $text).font(MFont.body).scrollContentBackground(.hidden).padding(MSpacing.m).frame(minHeight: 120)
                    .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                    .accessibilityLabel("Your side")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(photoData == nil ? "Add a photo" : "Photo added", systemImage: photoData == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                }.buttonStyle(ChipButtonStyle())
                if env.settings.displayName.isBlank {
                    TextField("Your name (shown as “…'s side”)", text: Binding(get: { env.settings.displayName }, set: { env.settings.displayName = $0 }))
                        .padding(MSpacing.m).background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                }
                Spacer()
                Button(saving ? "Adding…" : "Add my side") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(text.isBlank && photoData == nil || saving)
            }
            .padding(MSpacing.l)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: photoItem) { _, item in Task { photoData = try? await item?.loadTransferable(type: Data.self) } }
        }
        .presentationDetents([.large])
    }

    private func save() {
        saving = true
        Task {
            await env.stories.addSide(story, text: text.trimmed, photo: photoData)
            Haptics.saved(); env.toast("Added. Send it back when you're ready.")
            dismiss()
        }
    }
}
