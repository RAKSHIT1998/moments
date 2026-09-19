import Foundation
import CryptoKit

/// The unit of the decentralised network: a small, signed, immutable record. Everything —
/// profiles, Moments, sides, comments, reactions, NOW, follows, joins, claims — is an event.
/// Anyone can verify an event with the author's public key; nobody can alter or forge one.
/// Events travel phone-to-phone (mesh) and through relays anyone can run. Non-public Moments
/// carry ciphertext: relays and strangers store bytes they cannot read.
struct SignedEvent: Codable, Sendable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case profile, moment, momentUpdate, join, leave, contribution, comment, reaction, now, nowJoin, follow, unfollow, report, claim, group, delete
    }
    var id: String              // hex SHA-256 of the canonical form
    var kind: Kind
    var author: String          // Curve25519 public key, base64
    var createdAt: Date
    /// Small routing/indexing hints in the clear: momentID, placeID, geo cell, visibility, kind-specific refs.
    var tags: [String: String]
    /// JSON payload; for non-public Moments an AES-GCM sealed box (base64) under the Moment key.
    var content: String
    var sig: String

    static func canonical(kind: Kind, author: String, createdAt: Date, tags: [String: String], content: String) -> Data {
        let sortedTags = tags.keys.sorted().map { "\($0)=\(tags[$0]!)" }.joined(separator: "&")
        return Data("v1|\(kind.rawValue)|\(author)|\(Int(createdAt.timeIntervalSince1970))|\(sortedTags)|\(content)".utf8)
    }

    /// Creates and signs. `createdAt` is truncated to seconds so canonical bytes are stable.
    static func make(kind: Kind, key: Curve25519.Signing.PrivateKey, createdAt: Date = .now, tags: [String: String] = [:], content: String) throws -> SignedEvent {
        let at = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        let author = key.publicKey.rawRepresentation.base64EncodedString()
        let canon = canonical(kind: kind, author: author, createdAt: at, tags: tags, content: content)
        let id = SHA256.hash(data: canon).map { String(format: "%02x", $0) }.joined()
        let sig = try key.signature(for: canon).base64EncodedString()
        return SignedEvent(id: id, kind: kind, author: author, createdAt: at, tags: tags, content: content, sig: sig)
    }

    var isValid: Bool {
        guard let pk = Data(base64Encoded: author), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk), let s = Data(base64Encoded: sig) else { return false }
        let canon = Self.canonical(kind: kind, author: author, createdAt: createdAt, tags: tags, content: content)
        let id2 = SHA256.hash(data: canon).map { String(format: "%02x", $0) }.joined()
        return id2 == id && key.isValidSignature(s, for: canon)
    }

    func payload<T: Decodable>(_ type: T.Type, momentKey: SymmetricKey? = nil) -> T? {
        var data = Data(content.utf8)
        if tags["enc"] == "1" {
            guard let k = momentKey, let boxed = Data(base64Encoded: content), let box = try? AES.GCM.SealedBox(combined: boxed), let plain = try? AES.GCM.open(box, using: k) else { return nil }
            data = plain
        }
        return try? JSONDecoder.event.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T, momentKey: SymmetricKey?) throws -> (content: String, encrypted: Bool) {
        let data = try JSONEncoder.event.encode(value)
        guard let k = momentKey else { return (String(decoding: data, as: UTF8.self), false) }
        return (try AES.GCM.seal(data, using: k).combined!.base64EncodedString(), true)
    }
}

extension JSONEncoder { static let event: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }() }
extension JSONDecoder { static let event: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }() }

/// Per-Moment secret. Held by everyone who was invited; travels inside the invite link/QR, never through relays.
enum MomentKeys {
    static func new() -> SymmetricKey { SymmetricKey(size: .bits256) }
    static func string(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0).base64EncodedString() } }
    static func key(_ s: String) -> SymmetricKey? { Data(base64Encoded: s).map { SymmetricKey(data: $0) } }
    static func save(_ k: SymmetricKey, for momentID: String) { try? Keychain.set(k.withUnsafeBytes { Data($0) }, for: "momentkey.\(momentID)") }
    static func load(_ momentID: String) -> SymmetricKey? { Keychain.get("momentkey.\(momentID)").map { SymmetricKey(data: $0) } }
}

/// Coarse geo cell for routing public/NOW events through relays without exact coordinates: 0.1° ≈ 11 km.
enum GeoCell {
    static func cell(lat: Double, lon: Double) -> String { "\(Int((lat * 10).rounded(.down)))_\(Int((lon * 10).rounded(.down)))" }
    static func cells(lat: Double, lon: Double, radiusKm: Double) -> [String] {
        let steps = max(0, min(40, Int((radiusKm / 11).rounded(.up))))
        let cy = Int((lat * 10).rounded(.down)), cx = Int((lon * 10).rounded(.down))
        var out: [String] = []
        for dy in -steps...steps { for dx in -steps...steps { out.append("\(cy + dy)_\(cx + dx)") } }
        return out
    }
}
