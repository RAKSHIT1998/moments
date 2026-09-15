import Foundation
import SwiftUI

/// Locks the UI behind Face ID when the user has enabled it. Locks on background, unlocks on demand.
@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private let settings: SettingsStore
    let biometrics = BiometricLock()
    private var backgroundedAt: Date?

    init(settings: SettingsStore) {
        self.settings = settings
        isLocked = settings.requireBiometrics && biometrics.availability != .unavailable
    }

    func handleScenePhase(_ phase: ScenePhase) {
        // If the device no longer has any authentication method, locking would lock the user out of their own data.
        guard settings.requireBiometrics, biometrics.availability != .unavailable else { isLocked = false; return }
        switch phase {
        case .background: backgroundedAt = .now; isLocked = true
        case .active:
            if isLocked { Task { await unlock() } }
        default: break
        }
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await biometrics.authenticate() { isLocked = false }
    }

    /// Turning the lock on requires proving it works first, so the user is never locked out.
    func enableLock() async -> Bool {
        let ok = await biometrics.authenticate(reason: "Confirm to lock MOMENT with \(biometrics.label)")
        if ok { settings.requireBiometrics = true }
        return ok
    }

    func disableLock() async -> Bool {
        let ok = await biometrics.authenticate(reason: "Confirm to remove the lock")
        if ok { settings.requireBiometrics = false; isLocked = false }
        return ok
    }
}
