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

    init(storage: StorageService, settings: SettingsStore? = nil, provider: (any IntelligenceProvider)? = nil, mediaDirectory: URL? = nil) {
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
        actions.onChange = { [weak self] in self?.surface.noteDataChanged() }
        search.changeToken = { [weak self] in self?.surface.changeToken ?? 0 }
        importer.onChange = { [weak self] in self?.surface.noteDataChanged() }
        shareInbox.canCreateMemory = { [weak self] in
            guard let self else { return false }
            return self.subscriptions.canCreateMemory(currentCount: self.storage.memoryCount)
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
        let env = AppEnvironment(storage: StorageService.unavailable(), settings: SettingsStore(defaults: UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "preview-media-\(UUID().uuidString)"))
        if seed { DemoData.seed(into: env) }
        return env
    }
    #endif

    func openMemory(_ id: UUID) { pendingMemoryID = id }
}

enum RootTab: String, CaseIterable, Identifiable {
    case home, search, people, vault
    var id: String { rawValue }
    var label: String { switch self { case .home: "Home"; case .search: "Search"; case .people: "People"; case .vault: "Vault" } }
    var symbol: String { switch self { case .home: "house"; case .search: "magnifyingglass"; case .people: "person.2"; case .vault: "archivebox" } }
}
