import SwiftUI
import SwiftData
import UserNotifications
import BackgroundTasks
import CoreSpotlight
import CloudKit

@main
struct MomentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    private var preferredScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    init() {
        let env = AppEnvironment.live()
        _env = State(initialValue: env)
        AppDelegate.environment = env
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .preferredColorScheme(preferredScheme)
                .modelContainer(env.storage.container)
                .onOpenURL { env.handle(url: $0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let idString = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let id = UUID(uuidString: idString) { env.openMemory(id) }
                }
                .task { await env.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    env.lock.handleScenePhase(phase)
                    if phase == .active { Task { await env.becameActive() } }
                    if phase == .background { AppDelegate.scheduleRefresh() }
                }
        }
    }
}

/// Scene-based apps receive CloudKit share acceptance here, not on the app delegate.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        AppDelegate.acceptShare(cloudKitShareMetadata)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var environment: AppEnvironment?

    static let refreshTaskID = "com.rakshitbargotra.moment.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.handleRefresh(task as? BGAppRefreshTask)
        }
        #if DEBUG
        // UI tests: no animations, so XCUITest's idle detection isn't starved and runs stay fast.
        if ProcessInfo.processInfo.arguments.contains("-uitest") { UIView.setAnimationsEnabled(false) }
        #endif
        return true
    }

    /// Runs the SurfaceEngine in the background so "7 days before the birthday" fires even if the app hasn't been opened.
    private static func handleRefresh(_ task: BGAppRefreshTask?) {
        scheduleRefresh()
        let work = Task { @MainActor in
            guard let env = environment else { task?.setTaskCompleted(success: false); return }
            await env.shareInbox.drain()
            await env.surface.refresh()
            task?.setTaskCompleted(success: true)
        }
        task?.expirationHandler = { work.cancel(); task?.setTaskCompleted(success: false) }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date.now.addingTimeInterval(6 * 3600)
        do { try BGTaskScheduler.shared.submit(request) } catch { Log.app.debug("BG refresh not scheduled: \(error.localizedDescription)") }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.app.debug("APNs registered")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.app.debug("APNs unavailable: \(error.localizedDescription)")
    }

    /// Silent CloudKit push: something changed in a Moment I'm part of.
    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let isCloudKit = CKNotification(fromRemoteNotificationDictionary: userInfo) != nil
        Task { @MainActor in
            guard isCloudKit else { completionHandler(.noData); return }
            await Self.environment?.social.handleRemoteChange()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// The system hands us accepted CloudKit share invitations (tapped in Messages, AirDrop…).
    static func acceptShare(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            guard let env = Self.environment, let ck = env.social.backend as? CloudKitBackend else { return }
            do {
                let m = try await ck.accept(metadata)
                env.social.pendingMomentID = m.id
                env.analytics.track(.sharedMomentOpened)
                await env.social.refreshFeed()
            } catch { env.social.pendingInviteError = error.localizedDescription }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let momentID = response.notification.request.content.userInfo["momentID"] as? String {
            await MainActor.run { Self.environment?.social.pendingMomentID = momentID; Self.environment?.pendingTab = .home }
            return
        }
        guard let idString = response.notification.request.content.userInfo["memoryID"] as? String, let id = UUID(uuidString: idString) else { return }
        await MainActor.run {
            guard let env = Self.environment else { return }
            env.analytics.track(.notificationOpened)
            switch response.actionIdentifier {
            case NotificationService.actionDone:
                if let m = env.storage.memory(id: id) {
                    if let p = m.promises.first(where: { $0.status == .pending }) { env.actions.complete(p) } else { env.actions.completeTask(m) }
                    env.surface.recordUsefulResurface(m)
                }
            case NotificationService.actionRemindTomorrow:
                if let m = env.storage.memory(id: id) {
                    let tomorrow = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.now.adding(days: 1))
                    env.actions.setReminder(m, at: tomorrow)
                }
            default:
                env.openMemory(id)
            }
        }
    }
}

extension AppEnvironment {
    /// One-time launch work.
    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset-onboarding") { settings.onboardingCompleted = false }
        if ProcessInfo.processInfo.arguments.contains("-uitest") { settings.onboardingCompleted = true; settings.requireBiometrics = false }
        if ProcessInfo.processInfo.arguments.contains("-reset") { try? await lifecycle.deleteEverything(); settings.onboardingCompleted = true }
        if ProcessInfo.processInfo.arguments.contains("-demo") { await DemoData.seedAsync(into: self) }
        #endif
        // Social first: the feed is the first screen, and this is cheap (cached session + one fetch).
        await social.start()
        UIApplication.shared.registerForRemoteNotifications()
        LocalIntelligenceProvider.warmUp()
        await shareInbox.drain()
        await surface.refresh()
        await subscriptions.load()
    }

    func becameActive() async {
        let drained = await shareInbox.drain()
        if drained > 0 { pendingTab = .home; toast(drained == 1 ? "Remembered what you shared." : "Remembered \(drained) things you shared.") }
        if let last = surface.lastRefresh, last.daysUntil(.now) == 0, Date.now.timeIntervalSince(last) < 900, drained == 0 { return }
        await surface.refresh()
    }

    func handle(url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == MomentPackage.fileExtension {
            Task { await stories.importPackage(at: url) }
            return
        }
        if SocialService.isInviteURL(url) {
            Task { await social.acceptInvite(url) }
            return
        }
        guard url.scheme == AppGroup.urlScheme else { return }
        switch url.host() {
        case "moment":
            social.pendingMomentID = url.lastPathComponent
            pendingTab = .home
        case "memory":
            if let id = UUID(uuidString: url.lastPathComponent) { openMemory(id) }
        case "capture":
            showCapture = true
        case "inbox", "vault":
            pendingTab = .vault
        case "search":
            pendingTab = .search
        default: break
        }
    }
}
