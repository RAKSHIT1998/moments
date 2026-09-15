import Foundation

/// Release configuration read from Info.plist. Nothing here is invented: links are hidden until a
/// real URL is configured (`MomentSupportURL`, `MomentPrivacyPolicyURL`, `MomentTermsURL`).
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.rakshitbargotra.moment"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    static var supportURL: URL? { url("MomentSupportURL") }
    static var privacyPolicyURL: URL? { url("MomentPrivacyPolicyURL") }
    /// Defaults to Apple's standard EULA, which is a real, Apple-hosted page.
    static var termsURL: URL? { url("MomentTermsURL") }

    private static func url(_ key: String) -> URL? {
        guard let s = Bundle.main.infoDictionary?[key] as? String, !s.isEmpty, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }
}
