import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit

/// "SCAN TO JOIN OUR MOMENT" — a QR of the real share link, big enough for a table or a wall.
struct MomentQRSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let moment: SocialMoment
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var tint: Color = MColor.accent

    var body: some View {
        NavigationStack {
            VStack(spacing: MSpacing.xl) {
                Spacer()
                VStack(spacing: MSpacing.m) {
                    Text(moment.title).font(MFont.heroSmall).multilineTextAlignment(.center)
                    Text("SCAN TO JOIN").font(MFont.eyebrow).tracking(2).foregroundStyle(MColor.textSecondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).fill(.white).frame(width: 260, height: 260).shadow(color: tint.opacity(0.3), radius: 24, y: 10)
                        if let image { Image(uiImage: image).interpolation(.none).resizable().frame(width: 220, height: 220) } else { ProgressView() }
                    }
                    if let url { Text(url.host() ?? "").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                }
                Text("Anyone who scans gets the invite link. They join with their own iCloud account and add their side.").font(MFont.footnote).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center).padding(.horizontal, MSpacing.xl)
                Spacer()
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Join \(moment.title)", image: Image(uiImage: image))) { Label("Share QR", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, MSpacing.l)
                }
            }
            .background(MColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                tint = await env.social.tint(for: moment)
                var link = moment.shareURL
                if link == nil, moment.creatorID == env.social.myID { link = await env.social.shareLink(momentID: moment.id) }
                url = link
                if let link { image = MomentQR.make(link.absoluteString, tint: UIColor(tint)) }
            }
        }
    }
}

enum MomentQR {
    static func make(_ text: String, tint: UIColor = .black) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let colored = ci.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(color: tint), "inputColor1": CIColor.white])
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Live camera scanner for Moment QR codes (uses the system DataScanner; falls back with a message).
struct QRScannerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Point at a Moment QR"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    DataScannerRepresentable { code in
                        guard let url = URL(string: code) else { status = "That's not a link."; return }
                        if SocialService.isInviteURL(url) {
                            status = "Joining…"
                            Task { await env.social.acceptInvite(url); dismiss() }
                        } else if url.scheme == "moment" {
                            env.handle(url: url); dismiss()
                        } else { status = "That QR isn't a Moment." }
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Scanner unavailable", systemImage: "qrcode.viewfinder", description: Text("This device can't scan here. Open the link from Messages or Photos instead."))
                }
                Text(status).font(MFont.callout).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10).background(.black.opacity(0.55), in: Capsule()).padding(.bottom, 40)
            }
            .navigationTitle("Scan to join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var last: String?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { if case .barcode(let b) = item, let s = b.payloadStringValue, s != last { last = s; onCode(s) } }
        }
    }
}
