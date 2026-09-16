import SwiftUI
import PhotosUI

/// "What are we remembering?" → photos → when/where (from the photos) → who was there →
/// who can see it → create. Fast path: title + photos + create is three taps.
struct NewMomentView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var initial: SocialService.NewMomentInput? = nil
    var groupID: String? = nil
    var onCreated: ((SocialMoment) -> Void)? = nil

    @State private var title = ""
    @State private var description = ""
    @State private var place = ""
    @State private var visibility: MomentVisibility = .group
    @State private var isLive = false
    @State private var isTeaser = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [PhotoPick] = []
    @State private var videoURLs: [URL] = []
    @State private var people: [SocialUser] = []
    @State private var showPeople = false
    @State private var showCamera = false
    @State private var creating = false
    @State private var created: SocialMoment?
    @FocusState private var titleFocused: Bool

    struct PhotoPick: Identifiable, Equatable { let id = UUID(); let data: Data; let image: UIImage; let capturedAt: Date? }

    /// Built only from what's known (place, photo dates, people) — never invented.
    private var suggestedTitles: [String] {
        var out: [String] = []
        let dates = photos.compactMap(\.capturedAt).sorted()
        let year = Calendar.current.component(.year, from: dates.first ?? .now)
        if !place.isBlank { out.append("\(place.trimmed) '\(String(year).suffix(2))") }
        if let d = dates.first {
            let weekday = d.formatted(.dateTime.weekday(.wide))
            let hour = Calendar.current.component(.hour, from: d)
            out.append(hour >= 18 ? "\(weekday) night" : hour < 11 ? "\(weekday) morning" : weekday)
            if let last = dates.last, !Calendar.current.isDate(d, inSameDayAs: last) { out.append("\(d.formatted(.dateTime.month(.wide))) weekend") }
        }
        let names = people.map { $0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName }
        if names.count == 1 { out.append("With \(names[0])") }
        if names.count >= 2 { out.append("\(names[0]), \(names[1]) & co") }
        return out
    }

    private var dateRange: String? {
        let dates = photos.compactMap(\.capturedAt).sorted()
        guard let first = dates.first else { return nil }
        if let last = dates.last, !Calendar.current.isDate(first, inSameDayAs: last) { return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))" }
        return first.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("What are we remembering?").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    TextField("Goa '26, Sarah's 30th, Sunday run…", text: $title, axis: .vertical)
                        .font(MFont.hero).tracking(-0.4).lineLimit(1...3)
                        .focused($titleFocused)
                        .accessibilityIdentifier("newMomentTitle")
                    if title.isBlank, !suggestedTitles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MSpacing.s) {
                                ForEach(suggestedTitles, id: \.self) { t in Button(t) { title = t; Haptics.selection() }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("suggest-\(t)") }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                photoSection
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("WHEN & WHERE").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    if let dateRange { Label(dateRange, systemImage: "calendar").font(MFont.callout).foregroundStyle(MColor.textPrimary) }
                    else { Text("Dates come from your photos.").font(MFont.footnote).foregroundStyle(MColor.textTertiary) }
                    TextField("Place (city-level, e.g. Goa)", text: $place).textFieldStyle(.plain).padding(MSpacing.m)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                        .accessibilityIdentifier("newMomentPlace")
                    TextField("A line about it (optional)", text: $description, axis: .vertical).lineLimit(1...3).textFieldStyle(.plain).padding(MSpacing.m)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                }
                peopleSection
                visibilitySection
                Toggle(isOn: $isLive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Happening now").font(MFont.headline)
                        Text("Shows as LIVE; people can add as it happens.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                }
                .tint(MColor.accent)
                .accessibilityIdentifier("liveToggle")
                Toggle(isOn: $isTeaser) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mystery Moment").font(MFont.headline)
                        Text("Others see it blurred — \"You had to be there\" — until they tap Reveal.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                }
                .tint(MColor.accent)
                Button {
                    Task { await create() }
                } label: {
                    HStack { if creating { ProgressView().tint(.white) }; Text(creating ? "Creating…" : "Create Moment").frame(maxWidth: .infinity) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(title.isBlank || creating)
                .accessibilityIdentifier("createMoment")
                Text("Only the people you invite can see a Moment set to \"People in it\". You can change this any time.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l)
            .padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle("New Moment")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if let initial, title.isEmpty { title = initial.title; description = initial.description; visibility = initial.visibility }
            if let groupID, let g = env.social.groups.first(where: { $0.id == groupID }), people.isEmpty {
                // A group Moment: everyone in the group is invited from the start.
                for (id, name) in zip(g.memberIDs, g.memberNames) where id != env.social.myID { people.append(SocialUser(id: id, displayName: name, handle: "", bio: "", avatarRef: nil, isPrivateAccount: false, momentCount: 0, sharedCount: 0, placeCount: 0, peopleCount: 0, createdAt: .now)) }
                if title.isEmpty { title = "" }
            }
            if photos.isEmpty && initial == nil { titleFocused = true }
        }
        .onChange(of: pickerItems) { _, items in Task { await load(items) } }
        .sheet(isPresented: $showPeople) { PeoplePickerSheet(selected: $people) }
        .sheet(isPresented: $showCamera) { CameraPicker { data in if let img = UIImage(data: data) { photos.append(PhotoPick(data: data, image: img, capturedAt: .now)) } } }
        .navigationDestination(item: $created) { m in MomentPageView(momentID: m.id) }
        .modifier(SocialErrorAlert())
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack {
                Text("PHOTOS & VIDEO").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                Spacer()
                if !photos.isEmpty { Text("\(photos.count)").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.s) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 40, matching: .any(of: [.images, .videos])) {
                        VStack(spacing: 6) { Image(systemName: "photo.on.rectangle.angled").font(.title2); Text("Library").font(MFont.caption) }
                            .foregroundStyle(MColor.accent).frame(width: 96, height: 96)
                            .background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                    }
                    .accessibilityIdentifier("pickPhotos")
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            VStack(spacing: 6) { Image(systemName: "camera").font(.title2); Text("Camera").font(MFont.caption) }
                                .foregroundStyle(MColor.accent).frame(width: 96, height: 96)
                                .background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                        }
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-uitest") {
                        Button("Sample photos") { photos.append(contentsOf: SamplePhotos.make(3)) }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("samplePhotos")
                    }
                    #endif
                    ForEach(photos) { p in
                        Image(uiImage: p.image).resizable().scaledToFill().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { photos.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }.padding(4).accessibilityLabel("Remove photo")
                            }
                    }
                    ForEach(videoURLs, id: \.self) { url in
                        ZStack { RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous).fill(MColor.fill).frame(width: 96, height: 96); Image(systemName: "video.fill").foregroundStyle(MColor.textSecondary) }
                            .overlay(alignment: .topTrailing) { Button { videoURLs.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }.padding(4) }
                    }
                }
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("WHO WAS THERE").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
            FlowChips {
                ForEach(people) { u in
                    Button { people.removeAll { $0.id == u.id } } label: { Label(u.displayName, systemImage: "xmark").labelStyle(TrailingIconLabelStyle()) }.buttonStyle(ChipButtonStyle(prominent: true))
                }
                Button { showPeople = true } label: { Label("Add people", systemImage: "person.badge.plus") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("addPeople")
            }
            Text("They get an invite and can add their side. You can also share a link after.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
        }
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("WHO CAN SEE IT").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.s) {
                    ForEach(MomentVisibility.allCases, id: \.self) { v in
                        Button { visibility = v } label: { Label(v.label, systemImage: v.symbol) }.buttonStyle(ChipButtonStyle(prominent: visibility == v)).accessibilityIdentifier("vis-\(v.rawValue)")
                    }
                }
            }
            Text(visibility.explanation).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) { videoURLs.append(movie.url) }
            } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                photos.append(PhotoPick(data: data, image: img, capturedAt: PhotoMetadata.captureDate(from: data)))
            }
        }
        pickerItems = []
    }

    private func create() async {
        creating = true
        defer { creating = false }
        var input = initial ?? SocialService.NewMomentInput(title: title)
        input.title = title; input.description = description; input.visibility = visibility; input.isLive = isLive; input.isTeaser = isTeaser
        input.locationName = place.isBlank ? nil : place.trimmed
        input.photos = photos.map(\.data); input.videoURLs = videoURLs
        guard let m = await env.social.createMoment(input) else { return }
        if !people.isEmpty { _ = await env.social.shareLink(momentID: m.id, with: people.map(\.id)) }
        env.social.remixDraft = nil
        env.toast(people.isEmpty ? "Moment created." : "Moment created. \(people.count) invited.")
        if let onCreated { onCreated(m) } else { created = m }
    }
}

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appending(path: "pick-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 6) { configuration.title; configuration.icon.font(.caption) } }
}

/// Simple wrapping chip layout.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout(spacing: MSpacing.s) { content }
    }
}

/// Picks people from your graph or by handle.
struct PeoplePickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: [SocialUser]
    @State private var query = ""
    @State private var results: [SocialUser] = []

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty { Text(query.isEmpty ? "Search by name or @handle." : "No one found.").foregroundStyle(MColor.textSecondary) }
                ForEach(results) { u in
                    Button {
                        if let i = selected.firstIndex(where: { $0.id == u.id }) { selected.remove(at: i) } else { selected.append(u) }
                    } label: {
                        HStack { PersonAvatar(name: u.displayName, size: 36); VStack(alignment: .leading) { Text(u.displayName).foregroundStyle(MColor.textPrimary); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }; Spacer(); if selected.contains(where: { $0.id == u.id }) { Image(systemName: "checkmark.circle.fill").foregroundStyle(MColor.accent) } }
                    }
                    .accessibilityIdentifier("pick-\(u.handle)")
                }
            }
            .searchable(text: $query, prompt: "Name or @handle")
            .task(id: query) { results = await env.social.search(people: query) }
            .navigationTitle("Who was there?")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("peopleDone") } }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.sourceType = .camera; p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.9) { parent.onImage(data) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

#if DEBUG
enum SamplePhotos {
    static func make(_ n: Int) -> [NewMomentView.PhotoPick] {
        (0..<n).map { i in
            let colors: [UIColor] = [.systemOrange, .systemTeal, .systemPink, .systemIndigo]
            let img = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { ctx in colors[i % colors.count].setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 1200)) }
            return NewMomentView.PhotoPick(data: img.jpegData(compressionQuality: 0.8)!, image: img, capturedAt: .now.addingTimeInterval(Double(-i) * 1800))
        }
    }
}
#endif
