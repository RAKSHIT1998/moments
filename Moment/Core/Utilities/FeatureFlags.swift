import Foundation

/// Feature flags and experiment assignment. Defaults ship in the binary; a `FlagProvider` can
/// override them later (remote config) without touching call sites. Assignment is deterministic
/// per install so a user always sees the same variant.
protocol FlagProvider: Sendable {
    func value(for key: String) -> String?
}

struct DefaultsFlagProvider: FlagProvider {
    func value(for key: String) -> String? { UserDefaults.standard.string(forKey: "flag.\(key)") }
}

@MainActor
@Observable
final class FeatureFlags {
    enum Flag: String, CaseIterable {
        case photoFirstOnboarding   // onboarding asks for photos first
        case storyVideoExport       // video export available
        case monthRecap             // "Your month in Moments" card
        case remix                  // "Make your own" from received Moments
        case coreMemoryHints        // "This looks like a core memory"
        case shareCTAVariant        // A/B: "Share" vs "Send to someone who was there"
        case contextualInvites      // "Rahul was there too. Send it to him?"
    }

    private let provider: any FlagProvider
    private(set) var installID: String

    init(provider: any FlagProvider = DefaultsFlagProvider()) {
        self.provider = provider
        if let id = UserDefaults.standard.string(forKey: "installID") { installID = id }
        else { let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: "installID"); installID = id }
    }

    func isOn(_ flag: Flag) -> Bool {
        if let v = provider.value(for: flag.rawValue) { return v == "on" || v == "true" || v == "1" }
        switch flag {
        case .photoFirstOnboarding, .storyVideoExport, .monthRecap, .remix, .coreMemoryHints, .contextualInvites: return true
        case .shareCTAVariant: return false
        }
    }

    /// Stable bucket 0..<buckets for A/B tests, derived from the install id and the experiment name.
    func bucket(_ experiment: String, buckets: Int = 2) -> Int {
        var hash: UInt64 = 1469598103934665603
        for b in (installID + experiment).utf8 { hash ^= UInt64(b); hash = hash &* 1099511628211 }
        return Int(hash % UInt64(max(1, buckets)))
    }

    /// "Share" (A) vs "Send it to someone who was there" (B).
    var shareCTA: String {
        if let v = provider.value(for: Flag.shareCTAVariant.rawValue) { return v == "B" ? "Send to someone who was there" : "Share" }
        return bucket("shareCTA") == 1 ? "Send to someone who was there" : "Share"
    }
}
