import Foundation
import CryptoKit

/// AES-GCM encryption for media at rest (screenshots, audio). Uses a per-device symmetric key
/// stored in the Keychain. Standard CryptoKit only — no custom cryptography.
enum FileCrypto {
    private static let keychainKey = "media.encryption.key.v1"

    private static func key() throws -> SymmetricKey {
        if let data = Keychain.get(keychainKey) {
            return SymmetricKey(data: data)
        }
        if let data = try? Data(contentsOf: fallbackKeyURL) { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        do {
            try Keychain.set(data, for: keychainKey)
        } catch {
            // No Keychain (e.g. missing entitlement in an unsigned build): keep the key in a file that
            // iOS Data Protection encrypts with the device passcode. Never fail media storage.
            Log.security.error("Keychain unavailable for media key; using protected file fallback")
            try data.write(to: fallbackKeyURL, options: [.atomic, .completeFileProtection])
        }
        return fresh
    }

    private static var fallbackKeyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: ".media-key")
    }

    static func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key())
        guard let combined = sealed.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    static func decrypt(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key())
    }

    /// Called by "Delete All Data": destroys the key so any leftover ciphertext is unreadable.
    static func destroyKey() {
        Keychain.delete(keychainKey)
        try? FileManager.default.removeItem(at: fallbackKeyURL)
    }
}
