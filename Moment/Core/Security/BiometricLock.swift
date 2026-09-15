import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate. Only used when the user turns it on in Settings.
@MainActor
final class BiometricLock {
    enum Availability { case faceID, touchID, passcodeOnly, unavailable }

    var availability: Availability {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch ctx.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            default: return .passcodeOnly
            }
        }
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return .passcodeOnly }
        return .unavailable
    }

    var label: String {
        switch availability {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .passcodeOnly: "Passcode"
        case .unavailable: "Device lock"
        }
    }

    func authenticate(reason: String = "Unlock your memories") async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            Log.security.info("Biometric auth failed or cancelled")
            return false
        }
    }
}
