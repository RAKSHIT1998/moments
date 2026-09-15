import SwiftUI
import PhotosUI

/// Memory Drop: pick photos → MOMENT reads them through the real pipeline → a Moment.
struct MemoryDropView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onCreated: ((UUID) -> Void)? = nil
    @State private var items: [PhotosPickerItem] = []
    @State private var phase: Phase = .pick
    @State private var done = 0
    @State private var total = 0
    @State private var createdID: UUID?

    enum Phase: Equatable { case pick, loading, processing, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            switch phase {
            case .pick:
                Text("Memory Drop").eyebrowStyle().padding(.top, MSpacing.m)
                Text("Pick the photos. I'll find the story.").displayStyle()
                Text("Screenshots of chats become quotes, photos become the moments, and the people and places come along. 5–30 photos works best.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                PhotosPicker(selection: $items, maxSelectionCount: 30, matching: .images) {
                    Label("Choose photos", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("dropChoose")
                if !items.isEmpty { Text("\(items.count) selected").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                Spacer()
            case .loading:
                Spacer(); ProgressView(); Text("Loading photos…").font(MFont.body).foregroundStyle(MColor.textSecondary); Spacer()
            case .processing:
                Spacer()
                ProgressView(value: Double(done), total: Double(max(1, total)))
                Text("Reading \(min(done + 1, total)) of \(total)…").font(MFont.title).tracking(-0.3)
                Text("Understanding what's in them. This happens on your iPhone.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                Spacer()
            case .done:
                Spacer()
                Text("I found a story in these.").displayStyle()
                Button("Open it") { if let id = createdID { onCreated?(id) } }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("dropOpen")
                Spacer()
            case .failed:
                Spacer()
                Text("I couldn't read those.").font(MFont.title)
                Text("Try photos with faces, places or messages in them.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                Button("Try again") { phase = .pick; items = [] }.buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
        }
        .padding(MSpacing.l)
        .background(AmbientBackdrop(intensity: 0.6).ignoresSafeArea())
        .onChange(of: items) { _, new in if !new.isEmpty { Task { await run(new) } } }
    }

    private func run(_ picks: [PhotosPickerItem]) async {
        phase = .loading
        var datas: [Data] = []
        for item in picks { if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) } }
        guard !datas.isEmpty else { phase = .failed; return }
        total = datas.count
        phase = .processing
        if let story = await env.stories.memoryDrop(photos: datas, progress: { d, t in done = d; total = t }) {
            createdID = story.id
            Haptics.captureCompleted()
            phase = .done
            await env.surface.refresh(scheduleNotifications: false)
        } else { phase = .failed }
    }
}

/// Your Moments, what was shared with you, and the recaps. Lives in the Vault.
struct MomentsHubView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDrop = false
    @State private var openEditor: UUID?
    @State private var openViewer: UUID?

    var body: some View {
        let mine = env.stories.stories(includeReceived: false)
        let received = env.stories.received()
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Moments").eyebrowStyle().padding(.top, MSpacing.m)
                    Text("Make something worth sharing.").displayStyle()
                }
                HStack(spacing: MSpacing.s) {
                    action("Memory Drop", "photo.stack", "Photos → story") { showDrop = true }
                    action("This month", "calendar", Date.now.formatted(.dateTime.month(.wide))) { if let s = env.stories.monthRecap() { openEditor = s.id } else { env.toast("Capture a few more Moments this month first.") } }
                    action("Year", "sparkles", String(Calendar.current.component(.year, from: .now))) { if let s = env.stories.yearRecap(year: Calendar.current.component(.year, from: .now)) { openEditor = s.id } else { env.toast("Not enough yet for a year recap.") } }
                }
                if !received.isEmpty {
                    Text("Shared with you").eyebrowStyle().padding(.top, MSpacing.s)
                    ForEach(received) { s in Button { openViewer = s.id } label: { StoryRow(story: s) }.buttonStyle(PressScaleStyle()) }
                }
                Text("Yours").eyebrowStyle().padding(.top, MSpacing.s)
                if mine.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Nothing made yet.").font(MFont.headline)
                        Text("Drop in photos from a trip or a night out and MOMENT turns them into a story you can send to the people who were there.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }.momentCard()
                } else {
                    ForEach(mine) { s in Button { openEditor = s.id } label: { StoryRow(story: s) }.buttonStyle(PressScaleStyle()) }
                }
            }
            .padding(.horizontal, MSpacing.l).padding(.bottom, MSpacing.xxl)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle("")
        .sheet(isPresented: $showDrop) { NavigationStack { MemoryDropView { id in showDrop = false; openEditor = id }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDrop = false } } } } }
        .navigationDestination(item: $openEditor) { id in MomentEditorView(storyID: id) }
        .fullScreenCover(item: $openViewer) { id in NavigationStack { MomentViewerView(storyID: id).momentDestinations() } }
    }

    private func action(_ title: String, _ symbol: String, _ subtitle: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(MColor.accent).frame(width: 34, height: 34).background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.icon, style: .continuous))
                Text(title).font(MFont.headline)
                Text(subtitle).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .momentCard(padding: MSpacing.m)
        }
        .buttonStyle(PressScaleStyle())
    }
}

extension UUID: @retroactive Identifiable { public var id: UUID { self } }

struct StoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let story: MomentStory
    @State private var thumb: UIImage?
    var body: some View {
        HStack(spacing: MSpacing.m) {
            Group {
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() } else { MColor.accentGradient.overlay(Image(systemName: "sparkles").foregroundStyle(.white)) }
            }
            .frame(width: 56, height: 74).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(story.title).font(MFont.headline).lineLimit(1)
                Text(story.subtitle).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    ContextPill(text: story.kind.label, tone: .accent)
                    if story.isReceived, let a = story.originAuthor { Text("from \(a)").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                    if story.shareCount > 0 { Text("· shared \(story.shareCount)×").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                    if !story.reactions.isEmpty { Text(story.reactions.prefix(3).map { $0.reaction.emoji }.joined()).font(MFont.caption) }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MColor.textTertiary)
        }
        .momentCard(padding: MSpacing.m)
        .task { if let ref = story.coverSlide?.mediaRef ?? story.slides.first(where: { $0.mediaRef != nil })?.mediaRef { thumb = await env.media.thumbnail(ref, side: 240) } }
        .accessibilityElement(children: .combine)
    }
}

/// "You + Rahul" — stats and a timeline, then make it a Moment.
struct FriendshipView: View {
    @Environment(AppEnvironment.self) private var env
    let personID: UUID
    @State private var openEditor: UUID?

    var body: some View {
        if let p = env.storage.person(id: personID) { content(p) } else { EmptyStateView(symbol: "person.2", title: "Not found", message: "") }
    }

    private func content(_ p: Person) -> some View {
        let memories = p.visibleMemories.sorted { $0.createdAt < $1.createdAt }
        let places = Set(memories.flatMap(\.placeNamesCache))
        let plans = p.plans.filter { !$0.isDeleted }
        let photos = memories.filter { $0.imagePath != nil }.count
        let byYear = Dictionary(grouping: memories) { Calendar.current.component(.year, from: $0.createdAt) }
        return ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("You + \(p.displayName)").displayStyle().padding(.top, MSpacing.m)
                if let first = memories.first { Text("Since \(first.createdAt.formatted(.dateTime.month(.wide).year()))").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MSpacing.m) {
                    stat(memories.count, "shared moments"); stat(places.count, "places"); stat(plans.count, "plans"); stat(photos, "photos")
                }
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    Text("Timeline").eyebrowStyle()
                    ForEach(byYear.keys.sorted(), id: \.self) { year in
                        let items = byYear[year] ?? []
                        HStack(alignment: .top, spacing: MSpacing.m) {
                            Text(String(year)).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(MColor.accent).frame(width: 48, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(items.prefix(3)) { m in Text(m.title).font(MFont.body).lineLimit(1) }
                                if items.count > 3 { Text("+\(items.count - 3) more").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                            }
                        }
                    }
                }.momentCard()
                Button("Make this a Moment") {
                    if let s = env.stories.friendship(with: p) { openEditor = s.id } else { env.toast("Capture a couple more memories with \(p.displayName) first.") }
                }.buttonStyle(PrimaryButtonStyle())
                Button("Add another memory") { env.showCapture = true }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, MSpacing.l).padding(.bottom, MSpacing.xxl)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openEditor) { id in MomentEditorView(storyID: id) }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(MColor.accent)
            Text(label).font(MFont.caption).foregroundStyle(MColor.textSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading).momentCard(padding: MSpacing.m)
    }
}
