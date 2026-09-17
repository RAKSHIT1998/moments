import SwiftUI
import PhotosUI

/// ADD YOUR SIDE: your photos, a video, a note — into someone's Moment, attributed to you.
struct AddSideView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [NewMomentView.PhotoPick] = []
    @State private var videoURLs: [URL] = []
    @State private var note = ""
    @State private var showCamera = false
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                if let m = env.social.moments[momentID] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR SIDE OF").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                        Text(m.title).font(MFont.title)
                        Text("Shows next to \(m.memberNames.filter { $0 != env.social.displayName }.prefix(2).joined(separator: " and "))'s, with your name on it.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 40, matching: .any(of: [.images, .videos])) {
                            VStack(spacing: 6) { Image(systemName: "photo.on.rectangle.angled").font(.title2); Text("Library").font(MFont.caption) }
                                .foregroundStyle(MColor.accent).frame(width: 96, height: 96)
                                .background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                        }
                        .accessibilityIdentifier("sidePickPhotos")
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showCamera = true } label: {
                                VStack(spacing: 6) { Image(systemName: "camera").font(.title2); Text("Camera").font(MFont.caption) }
                                    .foregroundStyle(MColor.accent).frame(width: 96, height: 96)
                                    .background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                            }
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-uitest") {
                            Button("Sample photos") { photos.append(contentsOf: SamplePhotos.make(2)) }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("sideSamplePhotos")
                        }
                        #endif
                        ForEach(photos) { p in
                            Image(uiImage: p.image).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                                .overlay(alignment: .topTrailing) { Button { photos.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MColor.overlayLight, MColor.overlayDark.opacity(0.6)) }.padding(4) }
                        }
                        ForEach(videoURLs, id: \.self) { _ in
                            ZStack { RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous).fill(MColor.fill).frame(width: 96, height: 96); Image(systemName: "video.fill") }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("A NOTE").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    TextField("What do you remember?", text: $note, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).padding(MSpacing.m)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                        .accessibilityIdentifier("sideNote")
                }
                Button { Task { await send() } } label: { Text(sending ? "Adding…" : "Add my side").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled((photos.isEmpty && videoURLs.isEmpty && note.isBlank) || sending)
                    .accessibilityIdentifier("submitSide")
                Text("Your photos are compressed and stripped of location data before upload. You can remove them any time.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l)
        }
        .background(MColor.background)
        .navigationTitle("Add your side")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItems) { _, items in Task { await load(items) } }
        .sheet(isPresented: $showCamera) { CameraPicker { data in if let img = UIImage(data: data) { photos.append(NewMomentView.PhotoPick(data: data, image: img, capturedAt: .now)) } } }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) { videoURLs.append(movie.url) }
            } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                photos.append(NewMomentView.PhotoPick(data: data, image: img, capturedAt: PhotoMetadata.captureDate(from: data)))
            }
        }
        pickerItems = []
    }

    private func send() async {
        sending = true
        await env.social.addSide(momentID: momentID, photos: photos.map(\.data), videoURLs: videoURLs, note: note)
        sending = false
        env.toast("Added. Uploading in the background.")
        dismiss()
    }
}
