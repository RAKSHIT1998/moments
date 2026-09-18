import Foundation
import StoreKit

/// StoreKit 2. Prices come from the App Store, never hardcoded. Basic data access is never gated.
@MainActor
@Observable
final class SubscriptionService {
    enum ProductID: String, CaseIterable {
        case monthly = "moment_pro_monthly"
        case yearly = "moment_pro_yearly"
        case lifetime = "moment_pro_lifetime"
    }

    enum Tier: Equatable { case free, pro }

    static let freeMemoryLimit = 100
    /// Hosting limits for QR activities. Free is deliberately generous — charging comes later, and
    /// this is the one place the number lives.
    static let freeEventAttendees = 100
    static let freeOpenEventsPerMonth = 10

    private(set) var products: [Product] = []
    private(set) var tier: Tier = .free
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var activeProductID: String?
    private var updatesTask: Task<Void, Never>?

    var isPro: Bool { tier == .pro }

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                if case .verified(let t) = update { await t.finish() }
                await self.refreshEntitlements()
            }
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: ProductID.allCases.map(\.rawValue)).sorted { $0.price < $1.price }
            lastError = nil
        } catch {
            lastError = "Couldn't load prices. \(error.localizedDescription)"
            Log.store.error("Product load failed: \(error.localizedDescription)")
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var pro = false
        var active: String?
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement, ProductID(rawValue: t.productID) != nil, t.revocationDate == nil {
                pro = true; active = t.productID
            }
        }
        tier = pro ? .pro : .free
        activeProductID = active
    }

    func purchase(_ product: Product, analytics: AnalyticsService) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    await refreshEntitlements()
                    analytics.track(.subscriptionStarted, category: product.id)
                    return true
                }
                lastError = "Purchase couldn't be verified."
                return false
            case .userCancelled, .pending: return false
            @unknown default: return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Free tier: 100 memories. The check is only for *creating new* memories; viewing/exporting/deleting is never gated.
    /// Can this host admit one more person? Pro: always. Free: up to `freeEventAttendees`.
    func canAdmit(attendees: Int) -> Bool { isPro || attendees < Self.freeEventAttendees }

    func canCreateMemory(currentCount: Int) -> Bool {
        isPro || currentCount < Self.freeMemoryLimit
    }
}
