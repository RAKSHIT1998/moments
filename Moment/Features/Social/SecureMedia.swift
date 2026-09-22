import SwiftUI
import UIKit
import Combine

/// What can actually be enforced about screen capture, and what can't.
///
/// - iOS **can** keep content out of screenshots and screen recordings if it is rendered inside the
///   secure layer UIKit uses for password fields. `SecureMediaView` does that: the paid photo is there
///   on screen, and a screenshot of it comes out empty.
/// - iOS **tells** us when a screenshot was taken and when the screen is being recorded or mirrored.
///   We hide paid content while capture is live, and tell the creator when someone shot their screen.
/// - Nothing stops a second phone photographing the screen, so every paid view is watermarked with the
///   viewer's MOMENT ID. A leak points at one account.
/// - On the web client none of this exists. Say so; don't imply otherwise.
@MainActor @Observable
final class ScreenGuard {
    static let shared = ScreenGuard()
    /// True while the screen is being recorded, mirrored or shared.
    private(set) var isCaptured = UIScreen.main.isCaptured
    /// Bumped every time a screenshot is taken; views can react.
    private(set) var screenshots = 0
    private(set) var lastScreenshot: Date?
    /// Someone is watching paid content right now — only then is a screenshot worth reporting.
    private var viewing: [String: String] = [:]   // token → creatorID
    var onCapture: ((_ creatorID: String, _ kind: String) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .sink { [weak self] _ in self?.note("screenshot") }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isCaptured = UIScreen.main.isCaptured
                if self.isCaptured { self.note("recording") }
            }
            .store(in: &cancellables)
    }
    private func note(_ kind: String) {
        if kind == "screenshot" { screenshots += 1; lastScreenshot = .now }
        for creatorID in Set(viewing.values) { onCapture?(creatorID, kind) }
    }
    /// Call while paid content from `creatorID` is on screen.
    func beginViewing(_ creatorID: String) -> String { let t = UUID().uuidString; viewing[t] = creatorID; return t }
    func endViewing(_ token: String) { viewing[token] = nil }
}

/// Hosts its content inside UIKit's secure entry layer, so screenshots and recordings of it are blank.
/// Not a guarantee against a camera pointed at the screen — nothing is.
struct SecureLayer<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        // The canvas inside a secure field is what the system excludes from captures.
        guard let canvas = field.layer.sublayers?.first?.delegate as? UIView else {
            let fallback = UIView(); fallback.addSubview(host.view); pin(host.view, to: fallback); return fallback
        }
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.addSubview(host.view)
        pin(host.view, to: canvas)
        context.coordinator.host = host
        return canvas
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.host?.rootView = content() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var host: UIHostingController<Content>? }

    private func pin(_ view: UIView, to parent: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
}

/// Paid media: capture-resistant, watermarked with the viewer's MOMENT ID, hidden while recording.
struct SecureMediaView: View {
    @Environment(AppEnvironment.self) private var env
    let ref: MediaRef?
    let creatorID: String
    var contentMode: ContentMode = .fill
    @State private var token: String?
    private var guard_: ScreenGuard { .shared }

    var body: some View {
        ZStack {
            if guard_.isCaptured {
                // Recording or mirroring: show nothing but say why.
                Rectangle().fill(.ultraThinMaterial)
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill").font(.title2)
                    Text("Hidden while your screen is being recorded").font(MFont.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(MColor.textSecondary).padding()
            } else {
                SecureLayer { SocialImage(ref: ref, contentMode: contentMode) }
                Watermark(text: env.identity.momentID)
            }
        }
        .onAppear { token = guard_.beginViewing(creatorID) }
        .onDisappear { if let token { guard_.endViewing(token) } }
        .accessibilityLabel("Paid photo")
    }
}

/// The viewer's own ID, tiled faintly across the image. Visible enough to trace a leak, quiet enough to look at.
struct Watermark: View {
    let text: String
    var body: some View {
        GeometryReader { g in
            let step: CGFloat = 150
            ZStack {
                ForEach(0..<Int(g.size.height / step + 2), id: \.self) { row in
                    ForEach(0..<Int(g.size.width / step + 2), id: \.self) { col in
                        Text(text)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.22))
                            .rotationEffect(.degrees(-28))
                            .position(x: CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2), y: CGFloat(row) * step)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
