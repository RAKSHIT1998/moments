import Foundation
import CryptoKit
import UIKit

/// Every install gets a unique cryptographic identity: a Curve25519 signing key that never leaves
/// the Keychain. The public key's fingerprint is the person's MOMENT ID (`MMT-7K3F-9Q2X-4LMB`).
/// There is no server-side password — the "password" is a generated 12-word recovery phrase that
/// encrypts a backup of the key, so the identity can move to a new phone without anyone in the middle.
@MainActor
@Observable
final class IdentityService {
    private static let keyItem = "identity.signing.v1"
    private(set) var privateKey: Curve25519.Signing.PrivateKey
    private(set) var createdAt: Date

    init() {
        if let data = Keychain.get(Self.keyItem), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            privateKey = key
            createdAt = UserDefaults.standard.object(forKey: "identity.createdAt") as? Date ?? .now
        } else {
            let key = Curve25519.Signing.PrivateKey()
            try? Keychain.set(key.rawRepresentation, for: Self.keyItem)
            UserDefaults.standard.set(Date.now, forKey: "identity.createdAt")
            privateKey = key
            createdAt = .now
        }
    }

    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }
    var publicKeyBase64: String { publicKey.rawRepresentation.base64EncodedString() }

    /// Human-readable, checksummed id derived from the public key. Stable for the life of the key.
    var momentID: String { Self.fingerprint(of: publicKey.rawRepresentation) }

    nonisolated static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no 0/O/1/I
        let bytes = Array(digest.prefix(8))
        var bits = 0, acc = 0, out = ""
        for b in bytes {
            acc = (acc << 8) | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        }
        let s = String(out.prefix(12))
        return "MMT-" + stride(from: 0, to: 12, by: 4).map { String(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 4)]) }.joined(separator: "-")
    }

    // MARK: Signing

    /// Signs content so anyone with the public key can check it wasn't altered or forged.
    func sign(_ message: String) -> String? {
        (try? privateKey.signature(for: Data(message.utf8)))?.base64EncodedString()
    }

    nonisolated static func verify(_ signatureBase64: String, message: String, publicKeyBase64: String) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64), let pk = Data(base64Encoded: publicKeyBase64), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk) else { return false }
        return key.isValidSignature(sig, for: Data(message.utf8))
    }

    /// Canonical string signed for a Moment: who, what, when. Changing any of it breaks the signature.
    nonisolated static func momentMessage(id: String, creatorID: String, title: String, createdAt: Date) -> String {
        "moment|\(id)|\(creatorID)|\(title)|\(Int(createdAt.timeIntervalSince1970))"
    }

    // MARK: Recovery phrase ("password") & backup

    /// 12 words from a 256-word list = 96 bits. Generated once, shown once, never stored by us.
    static func generateRecoveryPhrase() -> [String] {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { RecoveryWords.list[Int($0)] }
    }

    /// Strength check for a phrase the user types back (recovery / import).
    static func isValidPhrase(_ words: [String]) -> Bool { words.count == 12 && words.allSatisfy { RecoveryWords.list.contains($0.lowercased()) } }

    /// Encrypted key backup: AES-GCM with a key derived from the phrase. Safe to keep anywhere (iCloud Drive, Files, paper QR).
    func exportBackup(phrase: [String]) throws -> Data {
        let key = Self.derive(phrase)
        let sealed = try AES.GCM.seal(privateKey.rawRepresentation, using: key)
        let payload: [String: String] = ["v": "1", "id": momentID, "ct": sealed.combined!.base64EncodedString()]
        return try JSONEncoder().encode(payload)
    }

    /// Replaces this device's identity with a backed-up one. Returns the restored MOMENT ID.
    func importBackup(_ data: Data, phrase: [String]) throws -> String {
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        guard let ct = payload["ct"], let combined = Data(base64Encoded: ct) else { throw IdentityError.badBackup }
        let raw: Data
        do { raw = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: Self.derive(phrase)) } catch { throw IdentityError.wrongPhrase }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        try Keychain.set(key.rawRepresentation, for: Self.keyItem)
        privateKey = key
        return momentID
    }

    private static func derive(_ phrase: [String]) -> SymmetricKey {
        // Stretch the phrase: 50k rounds of SHA-256 over phrase‖counter. Simple, dependency-free, and
        // the phrase itself already carries 96 bits of entropy.
        var h = Data(phrase.map { $0.lowercased() }.joined(separator: " ").utf8)
        for i in 0..<50_000 { var d = h; withUnsafeBytes(of: UInt32(i).bigEndian) { d.append(contentsOf: $0) }; h = Data(SHA256.hash(data: d)) }
        return SymmetricKey(data: h)
    }

    enum IdentityError: LocalizedError {
        case badBackup, wrongPhrase
        var errorDescription: String? { switch self { case .badBackup: "That file isn't a MOMENT identity backup."; case .wrongPhrase: "The recovery phrase doesn't match this backup." } }
    }
}

/// 256 short, distinct, easy-to-type words.
enum RecoveryWords {
    static let list: [String] = """
    acid amber anchor apple arrow atlas autumn badge bagel basil beach bell berry birch blade blaze bloom blue bold bonus brave bread brick bridge bright brook brush cabin cable cactus camel candle canoe cargo carve cedar chalk charm chess chief cider cinema civil clay clear cliff cloud coast cobalt comet copper coral cotton crane cream crisp crown crystal cubic curve cycle daisy dance dawn delta denim desert dome dove dragon dream drift drum dune eagle early earth echo elbow ember empire engine epic equal ether fable falcon fancy feather fern fiber field flame flash fleet flint flora fluid focus forest forge fossil frame fresh frost galaxy garden gentle giant ginger glass globe glow gold grace grain grape gravel green grove guide harbor hazel heart hedge hero hidden hill honey horizon humble ice indigo iron island ivory jade jaguar jasper jelly jewel jolly jungle karma kettle kite knight koala lagoon lantern laser lava leaf legend lemon level light lilac linen lion lotus lucky lunar magic magnet mango maple marble meadow melon mesa metal mint mirror misty model motor mural noble north nova oak oasis ocean olive onyx opal orbit orchid otter oyster paddle palm panda paper pearl pebble pepper petal piano pilot pine pixel planet plum polar prism pulse quartz quest quiet rabbit radar rain raven relic ridge river robin rocket rose ruby saddle sage salt sand satin scout shadow shell shore silk silver sketch slate smile snow solar sonic spark spice spirit spring spruce stone storm sugar summit sunny swift tango teal thunder tiger timber topaz torch tower trail tulip tundra twin umber unity urban valley velvet venus vivid vortex wagon walnut water wave willow winter wolf yellow zebra zenith zephyr zinc
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}
