import Foundation
import SwiftUI

/// User preferences that don't belong in the data store. Backed by UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
        useCloudAI = defaults.bool(forKey: "useCloudAI")
        requireBiometrics = defaults.bool(forKey: "requireBiometrics")
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        socialNotifications = defaults.object(forKey: "socialNotifications") as? Bool ?? true
        featuredMomentIDs = defaults.stringArray(forKey: "featuredMomentIDs") ?? []
        setupCompleted = defaults.bool(forKey: "setupCompleted")
        demoMode = defaults.bool(forKey: "demoMode")
        networkMode = NetworkMode(rawValue: defaults.string(forKey: "networkMode") ?? "") ?? .mesh
        relayURLs = defaults.stringArray(forKey: "relayURLs") ?? NetworkMode.defaultRelays
        meshEnabled = defaults.object(forKey: "meshEnabled") as? Bool ?? true
        webCheckoutEnabled = defaults.bool(forKey: "webCheckoutEnabled")
        checkoutBaseURL = defaults.string(forKey: "checkoutBaseURL") ?? ""
        turnURL = defaults.string(forKey: "turnURL") ?? ""
        turnUsername = defaults.string(forKey: "turnUsername") ?? ""
        turnCredential = defaults.string(forKey: "turnCredential") ?? ""
        dailyNotificationBudget = defaults.object(forKey: "dailyNotificationBudget") as? Int ?? 2
        lockScreenWidgetAllowed = defaults.bool(forKey: "lockScreenWidgetAllowed")
        analyticsEnabled = defaults.bool(forKey: "analyticsEnabled")
        calendarConnected = defaults.bool(forKey: "calendarConnected")
        dailyBriefEnabled = defaults.object(forKey: "dailyBriefEnabled") as? Bool ?? true
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
        demoLoaded = defaults.bool(forKey: "demoLoaded")
        hasSeenTryIt = defaults.bool(forKey: "hasSeenTryIt")
        notificationNudgeDismissed = defaults.bool(forKey: "notificationNudgeDismissed")
        notificationDetails = defaults.bool(forKey: "notificationDetails")
        categoryFeedback = defaults.dictionary(forKey: "categoryFeedback") as? [String: Double] ?? [:]
        homeDensity = HomeDensity(rawValue: defaults.string(forKey: "homeDensity") ?? "") ?? .balanced
        showPeopleOnHome = defaults.object(forKey: "showPeopleOnHome") as? Bool ?? true
        showPlansOnHome = defaults.object(forKey: "showPlansOnHome") as? Bool ?? true
        showMemoriesOnHome = defaults.object(forKey: "showMemoriesOnHome") as? Bool ?? true
        storyExportsMonthKey = defaults.string(forKey: "storyExportsMonthKey") ?? ""
        storyExportsThisMonth = defaults.integer(forKey: "storyExportsThisMonth")
        lastMonthRecapShown = defaults.string(forKey: "lastMonthRecapShown") ?? ""
        displayName = defaults.string(forKey: "displayName") ?? ""
    }
    /// Free-tier budget for rendered exports (images/video/packages) per calendar month.
    var storyExportsMonthKey: String { didSet { defaults.set(storyExportsMonthKey, forKey: "storyExportsMonthKey") } }
    var storyExportsThisMonth: Int { didSet { defaults.set(storyExportsThisMonth, forKey: "storyExportsThisMonth") } }
    var lastMonthRecapShown: String { didSet { defaults.set(lastMonthRecapShown, forKey: "lastMonthRecapShown") } }
    /// The name stamped on Moments you send ("Rahul's side"). Only what the user typed.
    var displayName: String { didSet { defaults.set(displayName, forKey: "displayName") } }

    enum HomeDensity: String, CaseIterable { case minimal, balanced, detailed
        var limit: Int { switch self { case .minimal: 3; case .balanced: 6; case .detailed: 10 } }
        var label: String { rawValue.capitalized }
    }
    /// Learned category preference from "useful / not useful". Multiplier around 1.0, clamped.
    var categoryFeedback: [String: Double] { didSet { defaults.set(categoryFeedback, forKey: "categoryFeedback") } }
    var homeDensity: HomeDensity { didSet { defaults.set(homeDensity.rawValue, forKey: "homeDensity") } }
    var showPeopleOnHome: Bool { didSet { defaults.set(showPeopleOnHome, forKey: "showPeopleOnHome") } }
    var showPlansOnHome: Bool { didSet { defaults.set(showPlansOnHome, forKey: "showPlansOnHome") } }
    var showMemoriesOnHome: Bool { didSet { defaults.set(showMemoriesOnHome, forKey: "showMemoriesOnHome") } }

    func recordFeedback(category: String, useful: Bool) {
        let current = categoryFeedback[category] ?? 1
        categoryFeedback[category] = max(0.4, min(1.6, current + (useful ? 0.08 : -0.12)))
    }
    /// Off by default: notifications say *that* something matters, not *what*, until the user opts in.
    var notificationDetails: Bool { didSet { defaults.set(notificationDetails, forKey: "notificationDetails") } }
    var notificationNudgeDismissed: Bool { didSet { defaults.set(notificationNudgeDismissed, forKey: "notificationNudgeDismissed") } }

    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    /// OFF by default. Sends the selected capture (only) to the cloud provider.
    var useCloudAI: Bool { didSet { defaults.set(useCloudAI, forKey: "useCloudAI") } }
    var requireBiometrics: Bool { didSet { defaults.set(requireBiometrics, forKey: "requireBiometrics") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    /// "Rahul added 8 photos" style alerts for shared Moments.
    var socialNotifications: Bool { didSet { defaults.set(socialNotifications, forKey: "socialNotifications") } }
    /// Moments pinned to the top of your profile (private preference; up to 3).
    var featuredMomentIDs: [String] { didSet { defaults.set(featuredMomentIDs, forKey: "featuredMomentIDs") } }
    /// The one-time setup checklist after onboarding (profile photo, notifications, people, group).
    var setupCompleted: Bool { didSet { defaults.set(setupCompleted, forKey: "setupCompleted") } }
    /// DEBUG builds only: run against the in-process backend with sample people and Moments.
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }
    /// How Moments reach other people. `mesh` = phone-to-phone + open relays, no company database.
    var networkMode: NetworkMode { didSet { defaults.set(networkMode.rawValue, forKey: "networkMode") } }
    var relayURLs: [String] { didSet { defaults.set(relayURLs, forKey: "relayURLs") } }
    var meshEnabled: Bool { didSet { defaults.set(meshEnabled, forKey: "meshEnabled") } }
    /// Card checkout on the web rail: the platform keeps 10% instead of Apple's 30%. Only legal to link
    /// out to from the app in storefronts where Apple allows it; off by default.
    var webCheckoutEnabled: Bool { didSet { defaults.set(webCheckoutEnabled, forKey: "webCheckoutEnabled") } }
    var checkoutBaseURL: String { didSet { defaults.set(checkoutBaseURL, forKey: "checkoutBaseURL") } }
    /// A TURN server of the user's own, for calls on networks that block direct connections. Empty by
    /// default: MOMENT runs none, so those calls fail honestly rather than routing through a stranger.
    var turnURL: String { didSet { defaults.set(turnURL, forKey: "turnURL") } }
    var turnUsername: String { didSet { defaults.set(turnUsername, forKey: "turnUsername") } }
    var turnCredential: String { didSet { defaults.set(turnCredential, forKey: "turnCredential") } }
    var dailyNotificationBudget: Int { didSet { defaults.set(dailyNotificationBudget, forKey: "dailyNotificationBudget") } }
    var lockScreenWidgetAllowed: Bool { didSet { defaults.set(lockScreenWidgetAllowed, forKey: "lockScreenWidgetAllowed") } }
    var analyticsEnabled: Bool { didSet { defaults.set(analyticsEnabled, forKey: "analyticsEnabled") } }
    var calendarConnected: Bool { didSet { defaults.set(calendarConnected, forKey: "calendarConnected") } }
    var dailyBriefEnabled: Bool { didSet { defaults.set(dailyBriefEnabled, forKey: "dailyBriefEnabled") } }
    var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: "recentSearches") } }
    var demoLoaded: Bool { didSet { defaults.set(demoLoaded, forKey: "demoLoaded") } }
    var hasSeenTryIt: Bool { didSet { defaults.set(hasSeenTryIt, forKey: "hasSeenTryIt") } }

    func rememberSearch(_ q: String) {
        let t = q.trimmed
        guard !t.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recentSearches.insert(t, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
    }

    func clearSearchHistory() { recentSearches = [] }

    func resetAll() {
        onboardingCompleted = false
        useCloudAI = false
        requireBiometrics = false
        notificationsEnabled = true
        socialNotifications = true
        featuredMomentIDs = []
        setupCompleted = false
        demoMode = false
        dailyNotificationBudget = 2
        lockScreenWidgetAllowed = false
        analyticsEnabled = false
        calendarConnected = false
        dailyBriefEnabled = true
        recentSearches = []
        demoLoaded = false
        hasSeenTryIt = false
        notificationNudgeDismissed = false
        notificationDetails = false
        categoryFeedback = [:]
        homeDensity = .balanced
        showPeopleOnHome = true; showPlansOnHome = true; showMemoriesOnHome = true
        storyExportsMonthKey = ""; storyExportsThisMonth = 0; lastMonthRecapShown = ""; displayName = ""
    }
}

enum NetworkMode: String, CaseIterable, Sendable {
    case mesh, icloud
    var label: String { self == .mesh ? "Decentralised" : "iCloud" }
    var explanation: String {
        self == .mesh ? "Signed events go phone-to-phone and through relays anyone can run. Nobody hosts your data — not even us."
                      : "Your Moments live in your own iCloud. Apple hosts the database; we still can't read it."
    }
    /// Community relays. Empty by default: the app works on mesh alone, and people add relays they trust.
    static let defaultRelays: [String] = []
}
