import Foundation

/// What two phones have to say to each other to open a call: an offer, an answer, and the network
/// candidates they might reach each other on. Nothing else — no media ever goes through here.
///
/// Every one of these is **sealed to the other person** before it leaves the device, because an ICE
/// candidate contains IP addresses. A relay forwarding a call setup learns that two keys are talking
/// and nothing more; it cannot read where either of them is.
struct CallSignal: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case offer          // SDP from the caller
        case answer         // SDP from the callee
        case candidate      // one ICE candidate
        case bye            // hang up
        case ready          // "I'm in the room, send me an offer"
    }
    var kind: Kind
    var bookingID: String
    var roomID: String
    /// SDP for `.offer` / `.answer`, the candidate string for `.candidate`, empty otherwise.
    var sdp: String = ""
    var sdpMid: String = ""
    var sdpMLineIndex: Int32 = 0
    /// Set on `.bye` so the other side can say why the call ended.
    var reason: String = ""
    var sentAt: Date = .now
}

/// Carries `CallSignal`s between the two people on a booking, sealed, over whatever network the app is
/// on. The backend decides how they travel; this protocol is all the call engine needs to know.
protocol CallSignalChannel: AnyObject, Sendable {
    /// Seals and sends one signal to the other person on this booking.
    func send(_ signal: CallSignal, to peerID: String) async
    /// Called for every signal addressed to me, already opened and verified as being from `peerID`.
    func onSignal(_ handler: @escaping @Sendable (CallSignal, String) -> Void) async
}

/// How a call reaches the other phone. STUN servers only tell a phone its own public address — they
/// see no traffic and hold no data, so the default list costs nothing and leaks nothing.
///
/// A TURN server is different: when a network refuses direct connections (some corporate and mobile
/// networks do), TURN forwards the *encrypted* media. It cannot read it — WebRTC's keys never reach it —
/// but it does see that a call is happening and it costs money to run. MOMENT ships **no TURN server**,
/// so those calls fail rather than quietly routing through somebody's machine. A creator who needs one
/// can add their own under Settings → Network, and the app says plainly what that means.
struct IceConfig: Codable, Sendable, Equatable {
    var stunServers: [String] = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302"
    ]
    /// Empty by default, on purpose. `urls` plus the credentials that server issued.
    var turnURLs: [String] = []
    var turnUsername: String = ""
    var turnCredential: String = ""

    var hasTurn: Bool { !turnURLs.isEmpty }

    /// What the user is told before their first call, in the two cases that actually differ.
    var explanation: String {
        hasTurn
        ? "Calls connect phone to phone. If your network blocks that, the call falls back to your TURN server, which forwards the call encrypted — it can't watch or hear it."
        : "Calls connect phone to phone, encrypted, with nothing in between. On a few networks that block direct connections the call won't go through; adding a TURN server under Settings → Network fixes those."
    }
}

/// Bridges whichever `SocialBackend` is live to the `CallEngine`. Nothing here decides how signals
/// travel — the backend does, because that's where the network is.
final class BackendCallChannel: CallSignalChannel, @unchecked Sendable {
    private let backend: any SocialBackend
    init(backend: any SocialBackend) { self.backend = backend }

    func send(_ signal: CallSignal, to peerID: String) async {
        try? await backend.sendCallSignal(signal, to: peerID)
    }
    func onSignal(_ handler: @escaping @Sendable (CallSignal, String) -> Void) async {
        await backend.onCallSignal(handler)
    }
}
