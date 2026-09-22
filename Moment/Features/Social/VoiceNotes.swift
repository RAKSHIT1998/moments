import SwiftUI
import AVFoundation

/// Press to talk. AAC in an .m4a, small enough to travel inside a sealed message.
@MainActor @Observable
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var seconds: Double = 0
    private(set) var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var timer: Timer?

    func start() async -> Bool {
        let granted: Bool = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        guard granted else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        let u = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return false }
        r.isMeteringEnabled = true; r.delegate = self
        guard r.record() else { return false }
        recorder = r; url = u; isRecording = true; seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters(); self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50); self.seconds = r.currentTime
                if self.seconds >= 120 { _ = self.stop() }
            }
        }
        return true
    }

    /// Returns the recorded file, or nil if it was too short to mean anything.
    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { url = nil }
        return seconds >= 0.6 ? url : nil
    }
    func cancel() { _ = stop(); if let url { try? FileManager.default.removeItem(at: url) } }
}

/// One player for the whole app so two notes never talk over each other.
@MainActor @Observable
final class VoiceNotePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceNotePlayer()
    private(set) var playingID: String?
    private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, data: Data) {
        if playingID == id { stop(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self; p.play(); player = p; playingID = id; progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in guard let self, let p = self.player else { return }; self.progress = p.duration > 0 ? p.currentTime / p.duration : 0 } }
    }
    func stop() { timer?.invalidate(); timer = nil; player?.stop(); player = nil; playingID = nil; progress = 0 }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor in self.stop() } }
    static func duration(of data: Data) -> Double { (try? AVAudioPlayer(data: data))?.duration ?? 0 }
}

/// Play button, bars, duration. The bars are decorative but deterministic per message (no fake "waveform" claims).
struct VoiceNoteBubble: View {
    @Environment(AppEnvironment.self) private var env
    let message: DirectMessage
    var mine: Bool
    @State private var data: Data?
    @State private var duration: Double = 0
    private var player: VoiceNotePlayer { .shared }

    var body: some View {
        HStack(spacing: MSpacing.m) {
            Button {
                if let data { player.toggle(id: message.id, data: data) }
            } label: {
                Image(systemName: player.playingID == message.id ? "pause.fill" : "play.fill").font(.headline).frame(width: 36, height: 36)
                    .background(Circle().fill(mine ? Color.white.opacity(0.25) : MColor.accent.opacity(0.18)))
            }
            .buttonStyle(.plain).disabled(data == nil).accessibilityLabel("Play voice note").accessibilityIdentifier("playVoice-\(message.id)")
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<28, id: \.self) { i in
                    let h = 6 + CGFloat(abs(message.id.hashValue &+ i * 7919) % 18)
                    let played = player.playingID == message.id && Double(i) / 28 < player.progress
                    Capsule().fill((mine ? Color.white : MColor.textPrimary).opacity(played ? 1 : 0.45)).frame(width: 3, height: h)
                }
            }
            Text(duration > 0 ? String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) : "…").font(MFont.caption).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .foregroundStyle(mine ? Color.white : MColor.textPrimary)
        .background {
            if mine { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)) }
        }
        .modifier(GlassWhen(enabled: !mine))
        .task {
            if let ref = message.media, let d = await env.social.data(for: ref) { data = d; duration = VoiceNotePlayer.duration(of: d) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice note, \(Int(duration)) seconds")
    }
    private struct GlassWhen: ViewModifier { var enabled: Bool; func body(content: Content) -> some View { if enabled { content.glass(radius: 20) } else { content } } }
}

/// Hold to record. Slide away to cancel. Shows time and a live level.
struct VoiceRecordButton: View {
    @State private var recorder = VoiceNoteRecorder()
    @State private var cancelling = false
    var onFinish: (URL) -> Void

    var body: some View {
        HStack(spacing: MSpacing.s) {
            if recorder.isRecording {
                HStack(spacing: 8) {
                    Circle().fill(MColor.danger).frame(width: 8, height: 8).opacity(0.6 + 0.4 * Double(recorder.level))
                    Text(String(format: "%d:%02d", Int(recorder.seconds) / 60, Int(recorder.seconds) % 60)).font(MFont.subheadline).monospacedDigit()
                    Text(cancelling ? "Release to cancel" : "Slide left to cancel").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).glassPill(tint: cancelling ? MColor.danger : nil)
                .transition(.opacity)
            }
            Image(systemName: "mic.fill").font(.title3).foregroundStyle(recorder.isRecording ? MColor.danger : MColor.textPrimary).frame(width: 36, height: 36)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !recorder.isRecording { Task { _ = await recorder.start() } }
                            cancelling = v.translation.width < -60
                        }
                        .onEnded { _ in
                            if cancelling { recorder.cancel() } else if let url = recorder.stop() { onFinish(url) }
                            cancelling = false
                        }
                )
                .accessibilityLabel("Hold to record a voice note").accessibilityIdentifier("recordVoice")
        }
        .animation(.easeOut(duration: 0.2), value: recorder.isRecording)
    }
}
