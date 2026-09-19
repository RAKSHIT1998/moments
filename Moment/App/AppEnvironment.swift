import Foundation
import SwiftUI
import SwiftData

/// Dependency container. Built once at launch, injected through the SwiftUI environment.
/// Tests build one with `inMemory: true` and a `MockIntelligenceProvider`.
@MainActor
@Observable
final class AppEnvironment {
    let storage: StorageService
    let media: MediaStore
    let settings: SettingsStore
    let analytics: AnalyticsService
    let notifications: NotificationService
    let importer: ImportService
    let actions: MemoryActions
    let surface: SurfaceService
    let search: SearchService
    let subscriptions: SubscriptionService
    let lifecycle: DataLifecycleService
    let shareInbox: ShareInboxService
    let calendar: CalendarService
    let contacts: ContactsService
    let lock: AppLockController
    let speech: SpeechService
    let stories: StoryService
    let flags: FeatureFlags
    let social: SocialService
    let location: LocationService
    let identity: IdentityService

    /// Deep-link / notification navigation target.
    var pendingMemoryID: UUID?
    var pendingTab: RootTab?
    var showCapture = false
    var pendingCaptureInput: CaptureInput?
    /// Set when the on-disk store couldn't be opened and the app is running on a temporary in-memory store.
    var storageUnavailable = false
    /// Understated confirmations ("Got it.", "Saved.").
    var toastText: String?
    private var toastTask: Task<Void, Never>?

    func toast(_ text: String) {
        toastText = text
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(1.6)); if !Task.isCancelled { toastText = nil } }
    }

    init(storage: StorageService, settings: SettingsStore? = nil, provider: (any IntelligenceProvider)? = nil, mediaDirectory: URL? = nil, backend: (any SocialBackend)? = nil) {
        self.storage = storage
        let settings = settings ?? SettingsStore()
        self.settings = settings
        self.media = MediaStore(directory: mediaDirectory)
        self.analytics = AnalyticsService(settings: settings)
        self.notifications = NotificationService(settings: settings)
        let importer = ImportService(storage: storage, media: media, settings: settings, analytics: analytics)
        importer.providerOverride = provider
        self.importer = importer
        self.actions = MemoryActions(storage: storage, media: media, notifications: notifications, analytics: analytics)
        self.surface = SurfaceService(storage: storage, notifications: notifications, settings: settings)
        self.search = SearchService(storage: storage, settings: settings, analytics: analytics)
        self.subscriptions = SubscriptionService()
        self.lifecycle = DataLifecycleService(storage: storage, media: media, settings: settings, notifications: notifications, analytics: analytics)
        self.shareInbox = ShareInboxService(importer: importer)
        self.calendar = CalendarService()
        self.contacts = ContactsService()
        self.lock = AppLockController(settings: settings)
        self.speech = SpeechService()
        self.stories = StoryService(storage: storage, media: media, importer: importer, settings: settings, analytics: analytics, subscriptions: subscriptions)
        self.flags = FeatureFlags()
        let identity = IdentityService()
        self.identity = identity
        self.social = SocialService(backend: backend ?? AppEnvironment.defaultBackend(media: media, settings: settings, identity: identity), media: media, settings: settings, analytics: analytics, queueDirectory: mediaDirectory)
        self.location = LocationService()
        social.subscriptions = subscriptions
        social.identity = identity
        actions.onChange = { [weak self] in self?.surface.noteDataChanged() }
        search.changeToken = { [weak self] in self?.surface.changeToken ?? 0 }
        importer.onChange = { [weak self] in self?.surface.noteDataChanged() }
        shareInbox.canCreateMemory = { [weak self] in
            guard let self else { return false }
            return self.subscriptions.canCreateMemory(currentCount: self.storage.memoryCount)
        }
    }

    /// Decentralised (mesh + relays) by default; iCloud is an opt-in alternative. In DEBUG, `-uitest`/`-demo`
    /// runs use the in-process backend so the simulator (no iCloud, no peers) exercises every flow against fictional people.
    static func defaultBackend(media: MediaStore, settings: SettingsStore, identity: IdentityService) -> any SocialBackend {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest") || args.contains("-demo") || settings.demoMode || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let b = InMemoryBackend(displayName: "Rakshit")
            Task { await b.seedDemo() }
            return b
        }
        #endif
        switch settings.networkMode {
        case .icloud: return CloudKitBackend(media: media)
        case .mesh: return DecentralizedBackend.live(identity: identity, media: media, settings: settings)
        }
    }

    static func live() -> AppEnvironment {
        do {
            return AppEnvironment(storage: try StorageService())
        } catch {
            Log.storage.critical("Persistent store failed (\(error.localizedDescription)); falling back to in-memory")
            // Never crash on launch, never silently lose data: run in memory and tell the user.
            let fallback = (try? StorageService(inMemory: true)) ?? StorageService.unavailable()
            let env = AppEnvironment(storage: fallback)
            env.storageUnavailable = true
            return env
        }
    }

    #if DEBUG
    /// For previews and tests.
    static func preview(seed: Bool = true) -> AppEnvironment {
        let backend = InMemoryBackend(displayName: "Rakshit")
        let env = AppEnvironment(storage: StorageService.unavailable(), settings: SettingsStore(defaults: UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "preview-media-\(UUID().uuidString)"), backend: backend)
        if seed { DemoData.seed(into: env); Task { await backend.seedDemo(); await env.social.start() } }
        return env
    }
    #endif

    func openMemory(_ id: UUID) { pendingMemoryID = id }

    #if DEBUG
    /// Switches the running app to the in-process social backend with sample people/Moments and
    /// seeds the private memory demo set. Persisted, so it survives relaunch until turned off.
    func enableDemoMode() async {
        settings.demoMode = true
        let backend = InMemoryBackend(displayName: settings.displayName.isBlank ? "Rakshit" : settings.displayName)
        await backend.seedDemo()
        social.replaceBackend(backend)
        await social.start()
        await DemoData.seedAsync(into: self)
        toast("Sample data loaded.")
    }

    func disableDemoMode() async {
        settings.demoMode = false
        settings.demoLoaded = false
        try? await lifecycle.deleteEverything()
        social.replaceBackend(AppEnvironment.defaultBackend(media: media, settings: settings, identity: identity))
        await social.start()
        toast("Sample data removed.")
    }
    #endif

    /// Switch between the decentralised network and iCloud. Data stays where it was; the app just talks to a different place.
    func setNetworkMode(_ mode: NetworkMode) async {
        guard settings.networkMode != mode else { return }
        settings.networkMode = mode
        #if DEBUG
        if settings.demoMode { return }
        #endif
        social.replaceBackend(AppEnvironment.defaultBackend(media: media, settings: settings, identity: identity))
        await social.start()
        toast(mode == .mesh ? "Decentralised." : "Using iCloud.")
    }

    /// Relay list changed: rebuild the transports on the running decentralised backend.
    func reloadRelays() async {
        guard settings.networkMode == .mesh, !settings.demoMode else { return }
        social.replaceBackend(AppEnvironment.defaultBackend(media: media, settings: settings, identity: identity))
        await social.start()
    }
}

enum RootTab: String, CaseIterable, Identifiable {
    case home, discover, create, now, profile
    var id: String { rawValue }
    var label: String { switch self { case .home: "Home"; case .discover: "Search"; case .create: "Create"; case .now: "Now"; case .profile: "Profile" } }
    var symbol: String { switch self { case .home: "house"; case .discover: "magnifyingglass"; case .create: "plus.app"; case .now: "bolt.circle"; case .profile: "person.crop.circle" } }
    static let inbox = RootTab.home
    /// Old deep links (`moment://search`, `vault`) still land somewhere sensible.
    static let search = RootTab.profile
    static let vault = RootTab.profile
    static let people = RootTab.profile
}
