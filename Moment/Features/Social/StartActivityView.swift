import SwiftUI

/// "Start an activity": pick what's happening, name it, tap once — you get a QR on screen.
/// Anyone with MOMENT scans it, lands in the Moment and adds their side. No photos needed to start.
struct StartActivityView: View {
    var body: some View { NavigationStack { StartActivityBody() } }
}

struct StartActivityBody: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SocialService.ActivityKind = .party
    @State private var title = ""
    @State private var place = ""
    @State private var openToAnyone = true
    @State private var starting = false
    @State private var started: SocialMoment?

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: MSpacing.xl) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Event").sectionLabel()
                        Text("What's happening?").displayStyle()
                        Text("You get a QR. People scan it and they're in — their photos land next to yours.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: MSpacing.s) {
                        ForEach(SocialService.ActivityKind.allCases, id: \.self) { k in
                            Button { kind = k; Haptics.selection() } label: {
                                VStack(spacing: 4) { Text(k.emoji).font(.title2); Text(k.label).font(MFont.caption) }
                                    .frame(maxWidth: .infinity).padding(.vertical, MSpacing.m)
                                    .background(kind == k ? MColor.accentSoft : MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous).strokeBorder(kind == k ? MColor.accent : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("kind-\(k.rawValue)")
                        }
                    }
                    TextField(kind.defaultTitle, text: $title).font(MFont.heroSmall).textFieldStyle(.plain).padding(MSpacing.m)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                        .accessibilityIdentifier("activityTitle")
                    TextField("Where, roughly (optional)", text: $place).textFieldStyle(.plain).padding(MSpacing.m)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                    Toggle(isOn: $openToAnyone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anyone with the QR can join").font(MFont.headline)
                            Text(openToAnyone ? "Best for parties, weddings, events. Up to \(SubscriptionService.freeEventAttendees) people on the free plan." : "Only friends you follow back can join, even with the QR.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                        }
                    }
                    .tint(MColor.accent)
                    Button { Task { await start() } } label: {
                        HStack { if starting { ProgressView().tint(.white) }; Label(starting ? "Starting…" : "Start & show QR", systemImage: "qrcode").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(starting).accessibilityIdentifier("startActivity")
                    Text("The Moment is live until you end it. Everyone keeps their own photos; you can remove anything from your activity.").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                .padding(MSpacing.l).padding(.bottom, MSpacing.xxl)
            }
            .background(MColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $started, onDismiss: { dismiss() }) { m in HostQRView(momentID: m.id) }
            .modifier(SocialErrorAlert())
    }

    private func start() async {
        starting = true
        defer { starting = false }
        if let m = await env.social.startActivity(title: title, kind: kind, place: place.isBlank ? nil : place, openToAnyone: openToAnyone) {
            Haptics.completed()
            started = m
        }
    }
}

/// Host screen: big QR, live attendee count, quick add, end. Keep it on the table.
struct HostQRView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var image: UIImage?
    @State private var tint: Color = MColor.accent
    @State private var showCamera = false
    @State private var confirmEnd = false
    @State private var lastCount = 0
    @State private var pulse = false

    private var moment: SocialMoment? { env.social.moments[momentID] }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5), MColor.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: MSpacing.l) {
                HStack {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(MFont.eyebrow).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5).background(MColor.danger, in: Capsule())
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white).frame(width: 36, height: 36).background(.black.opacity(0.25), in: Circle()) }.accessibilityLabel("Minimise")
                }
                Text(moment?.title ?? "").font(MFont.hero).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                Text("SCAN TO JOIN").font(MFont.eyebrow).tracking(2.5).foregroundStyle(.white.opacity(0.9))
                ZStack {
                    RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).fill(.white).shadow(color: .black.opacity(0.25), radius: 30, y: 16)
                    if let image { Image(uiImage: image).interpolation(.none).resizable().padding(22) } else { ProgressView() }
                }
                .frame(width: 280, height: 280)
                .scaleEffect(pulse ? 1.03 : 1)
                .animation(.spring(duration: 0.4), value: pulse)
                HStack(spacing: MSpacing.l) {
                    VStack(spacing: 2) {
                        Text("\(moment?.memberIDs.count ?? 1)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white).contentTransition(.numericText())
                        Text("here").font(MFont.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    VStack(spacing: 2) {
                        Text("\(moment?.contributionCount ?? 0)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white).contentTransition(.numericText())
                        Text("added").font(MFont.caption).foregroundStyle(.white.opacity(0.85))
                    }
                }
                if let names = moment?.memberNames.filter({ $0 != env.social.displayName }), !names.isEmpty {
                    HStack(spacing: 6) { AvatarStack(names: names, size: 26); Text(names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " + \(names.count - 2)" : "")).font(MFont.footnote).foregroundStyle(.white.opacity(0.9)).lineLimit(1) }
                }
                Spacer()
                HStack(spacing: MSpacing.s) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Add photo", systemImage: "camera.fill") }.buttonStyle(ChipButtonStyle(prominent: true, light: true))
                    }
                    NavigationLink(value: SocialRoute.moment(momentID)) { Label("Open", systemImage: "rectangle.stack") }.buttonStyle(ChipButtonStyle(light: true))
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Join \(moment?.title ?? "")", image: Image(uiImage: image))) { Label("Share QR", systemImage: "square.and.arrow.up") }.buttonStyle(ChipButtonStyle(light: true))
                    }
                    Button("End") { confirmEnd = true }.buttonStyle(ChipButtonStyle(light: true)).accessibilityIdentifier("endActivity")
                }
            }
            .padding(MSpacing.l)
        }
        .task {
            if let m = moment {
                tint = await env.social.tint(for: m)
                var link = m.shareURL
                if link == nil { link = await env.social.shareLink(momentID: m.id) }
                if let link { image = MomentQR.make(link.absoluteString, tint: .black) }
            }
            lastCount = moment?.memberIDs.count ?? 1
            // Poll while the QR is on screen so "3 here" ticks up as people scan (push covers the background).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await env.social.loadMoment(momentID)
                let n = moment?.memberIDs.count ?? lastCount
                if n > lastCount { lastCount = n; Haptics.completed(); pulse = true; try? await Task.sleep(for: .milliseconds(400)); pulse = false }
            }
        }
        .sheet(isPresented: $showCamera) { CameraPicker { data in Task { await env.social.addSide(momentID: momentID, photos: [data], note: ""); Haptics.saved() } } }
        .confirmationDialog("End this activity?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End — keep the Moment") { Task { if var m = moment { m.isLive = false; _ = await env.social.update(m) }; dismiss() } }
        } message: { Text("The QR stops admitting people. Everything added stays in the Moment.") }
        .environment(\.colorScheme, .dark)   // local to this view; preferredColorScheme would flip the whole window
        .accessibilityIdentifier("hostQR")
    }
}
