import Foundation
import AVFoundation
import WebRTC

/// One call, end to end. Audio and video go **directly between the two phones**, encrypted by WebRTC
/// (DTLS-SRTP); the only thing that crosses the relay is the sealed handshake in `CallSignaling`.
/// Nothing is recorded, nothing is uploaded, and there is no server in the middle to record it on.
///
/// The paid clock lives here too, and it starts on `connected` — not when the slot was booked — so
/// neither side loses paid minutes to the other one being late.
@MainActor
@Observable
final class CallEngine: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        /// The call is over. `reason` is what the person is told.
        case ended(reason: String)
        case failed(reason: String)

        var isLive: Bool { self == .connected || self == .reconnecting }
        var isOver: Bool { if case .ended = self { return true }; if case .failed = self { return true }; return false }
    }

    private(set) var state: State = .idle
    private(set) var clock: CallClock
    /// Ticks once a second while the call is live, so the countdown redraws.
    private(set) var now: Date = .now
    private(set) var remoteIsMuted = false
    private(set) var remoteVideoOn: Bool
    var micOn = true { didSet { audioTrack?.isEnabled = micOn } }
    var cameraOn: Bool { didSet { videoTrack?.isEnabled = cameraOn } }
    var speakerOn = true { didSet { routeAudio() } }
    /// Set when the paid time runs out and the goodbye grace period is running.
    private(set) var inGrace = false

    let booking: Booking
    let peerID: String
    let isCaller: Bool
    private let ice: IceConfig
    private weak var channel: (any CallSignalChannel)?

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var ticker: Task<Void, Never>?
    /// Candidates that arrived before the remote description was set.
    private var pendingCandidates: [RTCIceCandidate] = []
    private var usingFrontCamera = true

    private(set) var localVideo: RTCVideoTrack?
    private(set) var remoteVideo: RTCVideoTrack?

    /// The buyer is the caller: they paid, so their phone opens the connection.
    init(booking: Booking, me: String, channel: any CallSignalChannel, ice: IceConfig = IceConfig()) {
        self.booking = booking
        self.isCaller = me == booking.buyerID
        self.peerID = me == booking.buyerID ? booking.creatorID : booking.buyerID
        self.channel = channel
        self.ice = ice
        self.clock = CallClock(minutes: booking.paidMinutes)
        self.cameraOn = booking.kind.wantsCamera
        self.remoteVideoOn = booking.kind.wantsCamera
        super.init()
    }

    // MARK: Lifecycle

    /// Asks for the camera and microphone, opens the peer connection and starts signalling.
    /// Returns the reason it couldn't start, or nil.
    @discardableResult
    func start() async -> String? {
        guard case .idle = state else { return nil }
        state = .connecting

        if let denied = await requestPermissions() {
            state = .failed(reason: denied)
            return denied
        }

        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        self.factory = factory

        let config = RTCConfiguration()
        var servers = [RTCIceServer(urlStrings: ice.stunServers)]
        if ice.hasTurn { servers.append(RTCIceServer(urlStrings: ice.turnURLs, username: ice.turnUsername, credential: ice.turnCredential)) }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            let reason = "Couldn't open the call on this device."
            state = .failed(reason: reason)
            return reason
        }
        self.pc = pc

        configureAudioSession()
        addLocalMedia(factory: factory, to: pc)

        await channel?.onSignal { [weak self] signal, from in
            Task { @MainActor [weak self] in await self?.receive(signal, from: from) }
        }

        // The callee announces itself; the caller waits for that before making an offer, so the offer
        // never lands in an empty room and time out.
        if isCaller { await sendReady() } else { await sendReady() }
        if isCaller { await makeOffer() }

        startTicking()
        return nil
    }

    /// Ends the call and tells the other side why.
    func hangUp(reason: String = "Call ended") async {
        guard !state.isOver else { return }
        await send(CallSignal(kind: .bye, bookingID: booking.id, roomID: booking.roomID, reason: reason))
        finish(reason: reason)
    }

    private func finish(reason: String) {
        guard !state.isOver else { return }
        ticker?.cancel(); ticker = nil
        capturer?.stopCapture()
        pc?.close()
        pc = nil
        localVideo = nil; remoteVideo = nil
        state = .ended(reason: reason)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        RTCCleanupSSL()
    }

    // `finish` cancels the ticker; a deinit can't touch main-actor state, and the engine only ever dies
    // after the call screen has gone away.


    // MARK: Media

    private func requestPermissions() async -> String? {
        if await AVCaptureDevice.requestAccess(for: .audio) == false {
            return "MOMENT needs the microphone for calls. Settings › MOMENT › Microphone."
        }
        if booking.kind.wantsCamera, await AVCaptureDevice.requestAccess(for: .video) == false {
            return "MOMENT needs the camera for video calls. Settings › MOMENT › Camera."
        }
        return nil
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: booking.kind.wantsCamera ? .videoChat : .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        routeAudio()
    }

    private func routeAudio() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    private func addLocalMedia(factory: RTCPeerConnectionFactory, to pc: RTCPeerConnection) {
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = factory.audioTrack(with: audioSource, trackId: "mic0")
        pc.add(audio, streamIds: ["moment0"])
        audioTrack = audio

        guard booking.kind.wantsCamera else { return }
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.capturer = capturer
        let video = factory.videoTrack(with: videoSource, trackId: "cam0")
        pc.add(video, streamIds: ["moment0"])
        videoTrack = video
        localVideo = video
        startCapture()
    }

    private func startCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else { return }
        // 640×480-ish at 30fps: enough for a face, cheap enough for a mobile uplink.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let da = abs(Int(CMVideoFormatDescriptionGetDimensions(a.formatDescription).width) - 640)
            let db = abs(Int(CMVideoFormatDescriptionGetDimensions(b.formatDescription).width) - 640)
            return da < db
        }
        guard let format else { return }
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(30, fps)))
    }

    func switchCamera() {
        guard booking.kind.wantsCamera else { return }
        usingFrontCamera.toggle()
        capturer?.stopCapture { [weak self] in
            Task { @MainActor in self?.startCapture() }
        }
    }

    // MARK: Signalling

    private func send(_ s: CallSignal) async { await channel?.send(s, to: peerID) }
    private func sendReady() async { await send(CallSignal(kind: .ready, bookingID: booking.id, roomID: booking.roomID)) }

    private func makeOffer() async {
        guard let pc else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let offer = try? await pc.offer(for: constraints) else { return }
        try? await pc.setLocalDescription(offer)
        await send(CallSignal(kind: .offer, bookingID: booking.id, roomID: booking.roomID, sdp: offer.sdp))
    }

    private func receive(_ s: CallSignal, from: String) async {
        guard s.bookingID == booking.id, from == peerID, let pc else { return }
        switch s.kind {
        case .ready:
            // The other side just arrived. If I'm the caller and haven't offered yet, offer now.
            if isCaller, pc.localDescription == nil { await makeOffer() }
        case .offer:
            guard !isCaller else { return }
            try? await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: s.sdp))
            await drainCandidates()
            guard let answer = try? await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) else { return }
            try? await pc.setLocalDescription(answer)
            await send(CallSignal(kind: .answer, bookingID: booking.id, roomID: booking.roomID, sdp: answer.sdp))
        case .answer:
            guard isCaller else { return }
            try? await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: s.sdp))
            await drainCandidates()
        case .candidate:
            let c = RTCIceCandidate(sdp: s.sdp, sdpMLineIndex: s.sdpMLineIndex, sdpMid: s.sdpMid.isEmpty ? nil : s.sdpMid)
            if pc.remoteDescription == nil { pendingCandidates.append(c) } else { try? await pc.add(c) }
        case .bye:
            finish(reason: s.reason.isEmpty ? "They hung up" : s.reason)
        }
    }

    private func drainCandidates() async {
        guard let pc else { return }
        let queued = pendingCandidates
        pendingCandidates = []
        for c in queued { try? await pc.add(c) }
    }

    // MARK: The paid clock

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { self?.tick() }
            }
        }
    }

    private func tick() {
        now = .now
        guard clock.connectedAt != nil else { return }
        inGrace = clock.isOver(at: now)
        if clock.isHardOver(at: now) {
            Task { await hangUp(reason: "Time's up") }
        }
    }

    /// Adds time both sides agreed to, mid-call.
    func extend(byMinutes minutes: Int) {
        guard minutes > 0 else { return }
        clock.extraSeconds += minutes * 60
        inGrace = false
    }
}

// MARK: - RTCPeerConnectionDelegate

extension CallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.send(CallSignal(kind: .candidate, bookingID: self.booking.id, roomID: self.booking.roomID,
                                       sdp: candidate.sdp, sdpMid: candidate.sdpMid ?? "", sdpMLineIndex: candidate.sdpMLineIndex))
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !self.state.isOver else { return }
            switch newState {
            case .connected, .completed:
                // The one moment that starts the money clock.
                if self.clock.connectedAt == nil { self.clock.connectedAt = .now }
                self.state = .connected
            case .disconnected:
                self.state = .reconnecting
            case .failed:
                self.state = .failed(reason: self.failureHelp)
            case .closed:
                self.finish(reason: "Call ended")
            default:
                break
            }
        }
    }

    /// The honest version of "call failed": on most networks this means no direct path was found.
    private var failureHelp: String {
        ice.hasTurn
        ? "Couldn't connect, even through your TURN server. Try again on another network."
        : "Couldn't connect. One of you is on a network that blocks direct calls — try Wi-Fi, or add a TURN server under Settings › Network."
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak self] in
            if let track = rtpReceiver.track as? RTCVideoTrack { self?.remoteVideo = track }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    /// MOMENT sends no data over the call — only audio and video — so an opened channel is ignored.
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
