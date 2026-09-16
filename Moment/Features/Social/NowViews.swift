import SwiftUI
import PhotosUI

/// NOW: a photo or a line, gone in 24 hours. The composer is deliberately one screen.
struct NowComposerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var place = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: Data?
    @State private var showCamera = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                if let photo, let img = UIImage(data: photo) {
                    Image(uiImage: img).resizable().scaledToFill().frame(height: 260).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
                        .overlay(alignment: .topTrailing) { Button { self.photo = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.6)) }.padding(MSpacing.s) }
                }
                TextField("What's happening right now?", text: $text, axis: .vertical).font(.title3).lineLimit(1...5).focused($focused)
                    .accessibilityIdentifier("nowText")
                HStack(spacing: MSpacing.s) {
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Photo", systemImage: "photo") }.buttonStyle(ChipButtonStyle())
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }.buttonStyle(ChipButtonStyle()) }
                }
                TextField("Where (city, optional)", text: $place).textFieldStyle(.plain).padding(MSpacing.m)
                    .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                Spacer()
                Text("Visible to people you follow back. Disappears in 24 hours unless you save it to a Moment.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l)
            .background(MColor.background)
            .navigationTitle("NOW")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { Task { if await env.social.postNow(text: text, photo: photo, place: place.isBlank ? nil : place) { env.toast("Posted to NOW."); dismiss() } } }
                        .disabled(text.isBlank && photo == nil)
                        .accessibilityIdentifier("postNow")
                }
            }
            .onAppear { focused = true }
            .onChange(of: pickerItem) { _, item in Task { if let item, let d = try? await item.loadTransferable(type: Data.self) { photo = d } } }
            .sheet(isPresented: $showCamera) { CameraPicker { photo = $0 } }
        }
    }
}

/// Story-style NOW viewer: progress bars, tap right/left to move, auto-advance, swipe down to close.
struct NowViewerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let post: NowPost
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var dragY: CGFloat = 0
    private let seconds = 5.0

    private var posts: [NowPost] { env.social.nowPosts }
    private var current: NowPost { posts.indices.contains(index) ? posts[index] : post }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            NowPostView(post: current, paused: $paused)
                .id(current.id)
            // Progress bars
            HStack(spacing: 4) {
                ForEach(posts.indices, id: \.self) { i in
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white).frame(width: g.size.width * (i < index ? 1 : i == index ? progress : 0))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, MSpacing.l).padding(.top, 8)
            // Tap zones
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { go(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { go(1) }
            }
            .padding(.top, 90).padding(.bottom, 160)
            .onLongPressGesture(minimumDuration: 0.15, pressing: { paused = $0 }, perform: {})
        }
        .offset(y: dragY)
        .gesture(DragGesture().onChanged { if $0.translation.height > 0 { dragY = $0.translation.height } }.onEnded { if $0.translation.height > 120 { dismiss() } else { withAnimation(.spring(duration: 0.3)) { dragY = 0 } } })
        .onAppear { index = posts.firstIndex { $0.id == post.id } ?? 0 }
        .task(id: index) {
            progress = 0
            let step = 0.05
            while progress < 1 {
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
                if !paused { progress = min(1, progress + step / seconds) }
            }
            go(1)
        }
        .preferredColorScheme(.dark)
    }

    private func go(_ delta: Int) {
        let next = index + delta
        if next < 0 { index = 0; progress = 0; return }
        if next >= posts.count { dismiss(); return }
        index = next
    }
}

/// One NOW post: photo or ambient background, text, author, and "Save to a Moment".
struct NowPostView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let post: NowPost
    @Binding var paused: Bool
    @State private var showSave = false
    @State private var showReport = false

    var body: some View {
        ZStack(alignment: .top) {
            (post.media == nil ? AnyView(AmbientBackdrop(intensity: 1.2)) : AnyView(SocialImage(ref: post.media))).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack {
                HStack(spacing: MSpacing.s) {
                    PersonAvatar(name: post.authorName, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.authorID == env.social.myID ? "You" : post.authorName).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("\(post.createdAt.formatted(.relative(presentation: .named)))\(post.coarsePlace.map { " · \($0)" } ?? "")").font(MFont.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Menu {
                        if post.authorID == env.social.myID { Button("Delete", systemImage: "trash", role: .destructive) { Task { await env.social.deleteNow(post); dismiss() } } }
                        else { Button("Report", systemImage: "flag") { showReport = true }; Button("Mute \(post.authorName)", systemImage: "speaker.slash") { Task { await env.social.mute(post.authorID); dismiss() } } }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(.white).frame(width: 36, height: 36) }
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white).frame(width: 36, height: 36) }.accessibilityLabel("Close").accessibilityIdentifier("nowClose")
                }
                .padding(MSpacing.l).padding(.top, 14)
                Spacer()
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    if !post.text.isEmpty { Text(post.text).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).shadow(radius: 6) }
                    HStack(spacing: MSpacing.s) {
                        if post.savedToMomentID != nil {
                            Label("Saved to a Moment", systemImage: "checkmark").foregroundStyle(.white)
                        } else if post.authorID == env.social.myID || env.social.isFriend(post.authorID) {
                            Button { showSave = true } label: { Label("Save to a Moment", systemImage: "square.and.arrow.down") }.buttonStyle(ChipButtonStyle(prominent: true, light: true)).accessibilityIdentifier("saveNow")
                        }
                        Text("Gone in \(hoursLeft)h").font(MFont.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MSpacing.l)
            }
        }
        .sheet(isPresented: $showSave, onDismiss: { paused = false }) { SaveToMomentSheet(post: post) }
        .sheet(isPresented: $showReport, onDismiss: { paused = false }) { ReportSheet(userID: post.authorID) }
        .onChange(of: showSave) { _, v in if v { paused = true } }
        .onChange(of: showReport) { _, v in if v { paused = true } }
    }
    private var hoursLeft: Int { max(0, Int(post.expiresAt.timeIntervalSinceNow / 3600)) }
}

/// Pick which of your Moments keeps a NOW post — or make a new one for it.
struct SaveToMomentSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let post: NowPost
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Start a new Moment") {
                    HStack {
                        TextField("Title", text: $newTitle).accessibilityIdentifier("saveNewTitle")
                        Button("Create") {
                            Task {
                                if let m = await env.social.createMoment(SocialService.NewMomentInput(title: newTitle, visibility: .group)) { await env.social.saveNow(post, to: m.id); env.toast("Saved."); dismiss() }
                            }
                        }.disabled(newTitle.isBlank)
                    }
                }
                Section("Your Moments") {
                    ForEach(env.social.momentsImIn) { m in
                        Button { Task { await env.social.saveNow(post, to: m.id); env.toast("Saved to \(m.title)."); dismiss() } } label: {
                            HStack { SocialImage(ref: m.coverRef).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(m.title).foregroundStyle(MColor.textPrimary); Text(m.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) } }
                        }
                        .accessibilityIdentifier("saveTo-\(m.id)")
                    }
                }
            }
            .navigationTitle("Save to a Moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Photos/videos that arrived via the share sheet with "Add to a Moment".
struct AddSharedToMomentSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var thumbs: [UIImage] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: MSpacing.s) {
                            ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in Image(uiImage: img).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                            if thumbs.isEmpty { Text("\(env.shareInbox.pendingForMoment.count) items").foregroundStyle(MColor.textSecondary) }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Start a new Moment") {
                    HStack {
                        TextField("Title", text: $newTitle)
                        Button("Create") { Task { if let m = await env.social.createMoment(SocialService.NewMomentInput(title: newTitle, visibility: .group)) { await add(to: m.id) } } }.disabled(newTitle.isBlank)
                    }
                }
                Section("Your Moments") {
                    ForEach(env.social.momentsImIn) { m in
                        Button { Task { await add(to: m.id) } } label: {
                            HStack { SocialImage(ref: m.coverRef).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(m.title).foregroundStyle(MColor.textPrimary); Text(m.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) } }
                        }
                    }
                }
            }
            .navigationTitle("Add to a Moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Discard") { env.shareInbox.clearPendingForMoment(); dismiss() } } }
            .task { thumbs = env.shareInbox.pendingForMoment.filter { !$0.isVideo }.prefix(8).compactMap { (try? Data(contentsOf: $0.url)).flatMap { MediaPipeline.thumbnail($0, side: 200) }.flatMap(UIImage.init(data:)) } }
        }
    }

    private func add(to momentID: String) async {
        let items = env.shareInbox.pendingForMoment
        let photos = items.filter { !$0.isVideo }.compactMap { try? Data(contentsOf: $0.url) }
        let videos = items.filter(\.isVideo).map(\.url)
        await env.social.addSide(momentID: momentID, photos: photos, videoURLs: videos, note: "")
        env.shareInbox.clearPendingForMoment()
        env.toast("Adding \(items.count) to the Moment.")
        env.social.pendingMomentID = momentID
        dismiss()
    }
}
