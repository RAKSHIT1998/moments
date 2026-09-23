import SwiftUI
import WebRTC

/// A WebRTC track on screen. Metal-backed, so a 30fps remote feed costs almost nothing.
struct VideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirrored = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        v.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return v
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track?.add(view)
            context.coordinator.track = track
        }
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}

/// The call. A countdown of the time that was paid for, the other person, and four controls.
///
/// The clock is the point of this screen: both people see the same number, it starts when the call
/// actually connects, and it is never rounded in the creator's favour or the buyer's.
struct CallView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let booking: Booking

    @State private var engine: CallEngine?
    @State private var startError: String?
    @State private var showExtend = false
    @State private var confirmEnd = false
    @State private var recorded = false
    @State private var guardToken: String?

    private var isCreator: Bool { booking.creatorID == env.social.myID }
    private var theirName: String { isCreator ? booking.buyerName : booking.creatorName }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            remoteLayer
            VStack(spacing: 0) {
                header
                Spacer()
                if let engine, engine.state.isLive, booking.kind.wantsCamera { selfView }
                controls
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.bottom, MSpacing.l)
            if let engine, case .failed(let reason) = engine.state { failure(reason) }
            else if let startError { failure(startError) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // A paid call is paid content. The creator is told if the buyer screenshots or records it,
        // through the same guard that watches paid photos.
        .onAppear { guardToken = ScreenGuard.shared.beginViewing(booking.creatorID) }
        .task { await begin() }
        .onDisappear {
            if let guardToken { ScreenGuard.shared.endViewing(guardToken) }
            Task { await finish() }
        }
        .confirmationDialog("End this call?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End call", role: .destructive) { Task { await engine?.hangUp(reason: "They hung up"); await finish(); dismiss() } }
        } message: {
            Text(remaining > 60 ? "There are \(CallClock.label(remaining)) left. Ending now doesn't refund the rest." : "")
        }
        .sheet(isPresented: $showExtend) { ExtendCallSheet(booking: booking) { minutes in
            engine?.extend(byMinutes: minutes)
            Task { await env.social.recordCall(booking.id, connectedAt: nil, endedAt: nil, extraMinutes: minutes) }
        } }
        .accessibilityIdentifier("callView")
    }

    private var remaining: Int { engine.map { $0.clock.remaining(at: $0.now) } ?? booking.paidMinutes * 60 }

    // MARK: Layers

    @ViewBuilder private var remoteLayer: some View {
        if let engine, booking.kind.wantsCamera, let remote = engine.remoteVideo, engine.state.isLive {
            ZStack {
                if ScreenGuard.shared.isCaptured {
                    // Being recorded or mirrored: show nothing, and say why.
                    Rectangle().fill(.black)
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill").font(.title2)
                        Text("Hidden while your screen is being recorded").font(MFont.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8)).padding()
                } else {
                    SecureLayer { VideoTrackView(track: remote) }
                    Watermark(text: env.identity.momentID)
                }
            }
            .ignoresSafeArea()
        } else {
            LinearGradient(colors: [MColor.accent.opacity(0.35), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: MSpacing.l) {
                PersonAvatar(name: theirName, size: 120)
                Text(theirName).font(MFont.title).foregroundStyle(.white)
                Text(statusLine).font(MFont.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var statusLine: String {
        guard let engine else { return "Connecting…" }
        switch engine.state {
        case .idle, .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected: return booking.kind.wantsCamera ? "Camera off" : "On the call"
        case .ended(let r): return r
        case .failed(let r): return r
        }
    }

    @ViewBuilder private var selfView: some View {
        if let engine, let local = engine.localVideo, engine.cameraOn {
            HStack {
                Spacer()
                VideoTrackView(track: local, mirrored: true)
                    .frame(width: 104, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.2)))
            }
            .padding(.bottom, MSpacing.m)
        }
    }

    private var header: some View {
        HStack(spacing: MSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theirName).font(.headline).foregroundStyle(.white)
                Text(booking.kind.label).font(MFont.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            timer
        }
        .padding(.vertical, MSpacing.m)
    }

    /// The number both people are watching.
    private var timer: some View {
        let ending = engine.map { $0.clock.isEnding(at: $0.now) } ?? false
        let over = engine.map { $0.clock.isOver(at: $0.now) } ?? false
        return VStack(alignment: .trailing, spacing: 1) {
            Text(CallClock.label(remaining))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(over ? MColor.danger : (ending ? .orange : .white))
                .contentTransition(.numericText())
            Text(over ? "Time's up" : (engine?.clock.connectedAt == nil ? "\(booking.paidMinutes) min paid" : "left"))
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("callTimer")
        .accessibilityLabel("\(CallClock.label(remaining)) left")
    }

    private var controls: some View {
        VStack(spacing: MSpacing.m) {
            if let engine, engine.clock.isEnding(at: engine.now), !isCreator {
                Button { showExtend = true } label: {
                    Label(engine.clock.isOver(at: engine.now) ? "Add time to keep talking" : "Add time", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(filled: true))
                .accessibilityIdentifier("extendCall")
            }
            HStack(spacing: MSpacing.l) {
                circle(engine?.micOn == true ? "mic.fill" : "mic.slash.fill", on: engine?.micOn == true, id: "callMic") { engine?.micOn.toggle() }
                if booking.kind.wantsCamera {
                    circle(engine?.cameraOn == true ? "video.fill" : "video.slash.fill", on: engine?.cameraOn == true, id: "callCamera") { engine?.cameraOn.toggle() }
                    circle("arrow.triangle.2.circlepath.camera", on: true, id: "callFlip") { engine?.switchCamera() }
                } else {
                    circle(engine?.speakerOn == true ? "speaker.wave.2.fill" : "speaker.fill", on: engine?.speakerOn == true, id: "callSpeaker") { engine?.speakerOn.toggle() }
                }
                Button { confirmEnd = true } label: {
                    Image(systemName: "phone.down.fill").font(.title3).foregroundStyle(.white)
                        .frame(width: 62, height: 62).background(MColor.danger, in: Circle())
                }
                .accessibilityLabel("End call").accessibilityIdentifier("endCall")
            }
        }
    }

    private func circle(_ symbol: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).foregroundStyle(on ? .black : .white)
                .frame(width: 56, height: 56)
                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityIdentifier(id)
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: MSpacing.l) {
            Image(systemName: "phone.badge.waveform").font(.largeTitle).foregroundStyle(.white.opacity(0.8))
            Text("Couldn't connect").font(MFont.title).foregroundStyle(.white)
            Text(reason).font(MFont.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            if !isCreator {
                Text("You haven't lost the booking — it's still confirmed, and the clock never started.")
                    .font(MFont.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }
            Button("Close") { Task { await finish(); dismiss() } }.buttonStyle(GlassButtonStyle(filled: true))
        }
        .padding(MSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
        .accessibilityIdentifier("callFailed")
    }

    // MARK: Lifecycle

    private func begin() async {
        guard engine == nil else { return }
        let e = CallEngine(booking: booking, me: env.social.myID, channel: env.social.callChannel(), ice: env.social.iceConfig)
        engine = e
        startError = await e.start()
    }

    /// Writes down what actually happened, once, on this phone. Both sides write their own view;
    /// neither can invent minutes the other didn't see, because the clock started on a shared event.
    private func finish() async {
        guard !recorded, let engine else { return }
        recorded = true
        let connected = engine.clock.connectedAt
        await engine.hangUp()
        // A call that never connected costs nothing and stays booked.
        guard connected != nil else { return }
        await env.social.recordCall(booking.id, connectedAt: connected, endedAt: .now, extraMinutes: engine.clock.extraSeconds / 60)
    }

}

/// Buying more minutes without leaving the call. Same per-minute rate as the booking — no surge.
struct ExtendCallSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let booking: Booking
    let onExtend: (Int) -> Void
    @State private var minutes = 5

    private var perMinuteMinor: Int { booking.minutes > 0 ? booking.amountMinor / booking.minutes : 0 }
    private var costLabel: String {
        (Double(perMinuteMinor * minutes) / 100).formatted(.currency(code: booking.currency).precision(.fractionLength(0)))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("Add time").displayStyle()
                Text("Same rate as the booking: \((Double(perMinuteMinor) / 100).formatted(.currency(code: booking.currency).precision(.fractionLength(0)))) a minute.")
                    .font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                Picker("Minutes", selection: $minutes) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                Text(costLabel).font(MFont.hero)
                Text("\(booking.creatorName) keeps \(CreatorEconomics.creatorTake(perMinuteMinor * minutes, rail: env.social.rail).formatted(.currency(code: booking.currency).precision(.fractionLength(0)))) of that.")
                    .font(MFont.caption).foregroundStyle(MColor.textTertiary)
                Spacer()
                Button("Add \(minutes) minutes") { onExtend(minutes); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("confirmExtend")
            }
            .padding(MSpacing.page)
            .background(MColor.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// The waiting room: what was booked, when it starts, and a Join that only lights up in the window.
struct CallLobbyView: View {
    @Environment(AppEnvironment.self) private var env
    let bookingID: String
    @State private var showCall = false
    @State private var now = Date.now

    private var booking: Booking? { env.social.myBookings.first { $0.id == bookingID } }

    var body: some View {
        ScrollView {
            if let b = booking {
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Label(b.kind.label, systemImage: b.kind.symbol).font(MFont.eyebrow).foregroundStyle(MColor.accent)
                        Text(b.startsAt.formatted(date: .complete, time: .shortened)).font(MFont.title)
                        Text("\(b.paidMinutes) minutes · \(b.totalLabel())").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                        if !b.note.isBlank { Text(b.note).font(MFont.body).padding(.top, 2) }
                    }
                    .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()

                    countdown(b)

                    Button { showCall = true } label: {
                        Label("Join the call", systemImage: b.kind.wantsCamera ? "video.fill" : "phone.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!b.joinWindow().contains(now))
                    .accessibilityIdentifier("joinCall")

                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Label("The clock starts when you're both connected", systemImage: "clock")
                        Label("Screenshots and recordings come out blank", systemImage: "eye.slash")
                        Label(env.social.iceConfig.explanation, systemImage: "lock.shield")
                    }
                    .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    .padding(.top, MSpacing.s)
                }
                .padding(MSpacing.page)
            } else {
                Text("That booking isn't here any more.").font(MFont.body).foregroundStyle(MColor.textSecondary).padding(MSpacing.page)
            }
        }
        .background(MColor.background)
        .navigationTitle("Your call").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCall) { if let b = booking { CallView(booking: b) } }
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityIdentifier("callLobby")
    }

    @ViewBuilder private func countdown(_ b: Booking) -> some View {
        let window = b.joinWindow()
        if window.contains(now) {
            Label("You can join now", systemImage: "checkmark.circle.fill").font(MFont.headline).foregroundStyle(MColor.accent)
        } else if now < window.lowerBound {
            let secs = Int(window.lowerBound.timeIntervalSince(now))
            VStack(alignment: .leading, spacing: 2) {
                Text(secs > 3600 ? "Opens \(window.lowerBound.formatted(.relative(presentation: .named)))" : "Opens in \(CallClock.label(secs))")
                    .font(MFont.headline)
                Text("You can join five minutes early.").font(MFont.caption).foregroundStyle(MColor.textSecondary)
            }
        } else {
            Text("This one's window has passed.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
        }
    }
}
