import Foundation
import CloudKit
import CoreLocation
import UIKit

/// Production backend on CloudKit — Apple's hosted database, asset CDN and sharing system.
///
/// Layout
/// - Private DB, custom zone `MomentsZone`: `Moment` roots with `Contribution`/`Comment`/`Reaction`
///   children. A Moment shared with people gets a `CKShare`; members write their contributions
///   into the shared zone. The share URL is the invite deep link.
/// - Shared DB: Moments other people invited me to.
/// - Public DB: `Profile`, `Follow`, `PublicMoment` (mirror of public Moments for Discover), `Now`, `Report`.
/// - Private DB default zone: `Block`, `Mute`, `Settings`, `Seen`.
final class CloudKitBackend: SocialBackend, @unchecked Sendable {
    let name = "cloudkit"
    static let containerID = "iCloud.com.rakshitbargotra.moment"
    static let zoneName = "MomentsZone"

    let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }
    private var publicDB: CKDatabase { container.publicCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitBackend.zoneName, ownerName: CKCurrentUserDefaultName)
    private let media: MediaStore
    private var cachedUser: SocialUser?
    private var zoneReady = false
    private var coverCache: [String: String] = [:]
    private var shareURLCache: [String: URL?] = [:]

    init(media: MediaStore, container: CKContainer = CKContainer(identifier: CloudKitBackend.containerID)) {
        self.container = container
        self.media = media
    }

    // MARK: - Identity

    func accountStatus() async -> AccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .offline
            default: return .unknown
            }
        } catch { return .offline }
    }

    private func userRecordName() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw map(error) }
    }

    func currentUser() async throws -> SocialUser {
        if let cachedUser { return cachedUser }
        let uid = try await userRecordName()
        let id = CKRecord.ID(recordName: "profile_\(uid)")
        if let record = try? await publicDB.record(for: id) {
            let u = Self.user(from: record)
            cachedUser = u
            return u
        }
        // First launch: a minimal profile the user completes in onboarding.
        let record = CKRecord(recordType: "Profile", recordID: id)
        record["userID"] = uid
        record["displayName"] = "You"
        record["handle"] = "user\(uid.suffix(6).lowercased().filter { $0.isLetter || $0.isNumber })"
        record["bio"] = ""
        record["privateAccount"] = 0
        let saved = try await save(record, in: publicDB)
        let u = Self.user(from: saved)
        cachedUser = u
        return u
    }

    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async throws -> SocialUser {
        let uid = try await userRecordName()
        let id = CKRecord.ID(recordName: "profile_\(uid)")
        let record = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "Profile", recordID: id)
        record["userID"] = uid
        record["displayName"] = displayName
        record["handle"] = handle.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        record["bio"] = bio
        if let avatar, let url = try? Self.tempFile(avatar, ext: "jpg") { record["avatar"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: publicDB)
        let u = Self.user(from: saved)
        cachedUser = u
        return u
    }

    func publishIdentity(publicKey: String, momentID: String) async throws {
        let uid = try await userRecordName()
        let id = CKRecord.ID(recordName: "profile_\(uid)")
        let record = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "Profile", recordID: id)
        record["userID"] = uid; record["publicKey"] = publicKey; record["momentID"] = momentID
        cachedUser = Self.user(from: try await save(record, in: publicDB))
    }

    func user(id: String) async throws -> SocialUser {
        do { return Self.user(from: try await publicDB.record(for: CKRecord.ID(recordName: "profile_\(id)"))) } catch { throw map(error) }
    }

    func searchUsers(_ text: String) async throws -> [SocialUser] {
        let q = text.lowercased().trimmed
        guard !q.isEmpty else { return [] }
        let predicate = NSPredicate(format: "handle BEGINSWITH %@", q)
        let records = try await query(CKQuery(recordType: "Profile", predicate: predicate), in: publicDB, limit: 25)
        return records.map(Self.user(from:))
    }

    // MARK: - Moments

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        do {
            _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneReady = true
        } catch { throw map(error) }
    }

    func createMoment(_ draft: MomentDraft) async throws -> SocialMoment {
        try await ensureZone()
        let me = try await currentUser()
        let record = CKRecord(recordType: "Moment", recordID: CKRecord.ID(recordName: "moment_\(UUID().uuidString)", zoneID: zoneID))
        record["creatorID"] = me.id
        record["creatorName"] = me.displayName
        record["title"] = draft.title
        record["description"] = draft.description
        record["startAt"] = draft.startAt
        record["endAt"] = draft.endAt
        record["locationName"] = draft.locationName
        record["coarsePlace"] = draft.coarsePlace
        record["visibility"] = draft.visibility.rawValue
        record["memberIDs"] = [me.id]
        record["memberNames"] = [me.displayName]
        record["contributionCount"] = 0
        record["mediaCount"] = 0
        record["commentCount"] = 0
        record["shareCount"] = 0
        record["isLive"] = draft.isLive ? 1 : 0
        record["templateID"] = draft.templateID
        record["remixedFromID"] = draft.remixedFromID
        record["allowsReshare"] = 1
        record["allowsDownload"] = 1
        record["allowsContributions"] = 1
        record["isTeaser"] = draft.isTeaser ? 1 : 0
        Self.write(place: draft.place, to: record)
        if let signer = draft.signer { let at = Date.now; let s = signer(record.recordID.recordName, at); record["signature"] = s.signature; record["creatorPublicKey"] = s.publicKey; record["signedAt"] = at }
        if let cover = draft.coverData, let url = try? Self.tempFile(cover, ext: "jpg") { record["cover"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: privateDB)
        let moment = try await moment(from: saved)
        if draft.visibility == .publicAll || draft.visibility == .subscribers { try await mirrorPublic(moment, record: saved) }
        if draft.visibility == .subscribers { try? await grantSubscribers(momentID: moment.id) }
        return moment
    }

    func updateMoment(_ moment: SocialMoment) async throws -> SocialMoment {
        let (record, db) = try await momentRecord(id: moment.id)
        record["title"] = moment.title
        record["description"] = moment.description
        record["visibility"] = moment.visibility.rawValue
        record["locationName"] = moment.locationName
        record["coarsePlace"] = moment.coarsePlace
        record["isLive"] = moment.isLive ? 1 : 0
        record["allowsReshare"] = moment.allowsReshare ? 1 : 0
        record["allowsDownload"] = moment.allowsDownload ? 1 : 0
        record["allowsContributions"] = moment.allowsContributions ? 1 : 0
        record["isTeaser"] = moment.isTeaser ? 1 : 0
        let saved = try await save(record, in: db)
        let updated = try await self.moment(from: saved)
        if moment.visibility == .publicAll || moment.visibility == .subscribers { try await mirrorPublic(updated, record: saved) } else { _ = try? await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "public_\(moment.id)")) }
        return updated
    }

    func deleteMoment(id: String) async throws {
        let (record, db) = try await momentRecord(id: id)
        do { try await db.deleteRecord(withID: record.recordID) } catch { throw map(error) }
        _ = try? await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "public_\(id)"))
    }

    func moment(id: String) async throws -> SocialMoment {
        let (record, _) = try await momentRecord(id: id)
        return try await moment(from: record)
    }

    func myMoments(cursor: String?) async throws -> FeedPage<SocialMoment> {
        try await ensureZone()
        let q = CKQuery(recordType: "Moment", predicate: NSPredicate(value: true))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let records = try await query(q, in: privateDB, zone: zoneID, limit: 50)
        var out: [SocialMoment] = []
        for r in records { out.append(try await moment(from: r)) }
        return FeedPage(items: out, cursor: nil)
    }

    func sharedWithMe(cursor: String?) async throws -> FeedPage<SocialMoment> {
        var out: [SocialMoment] = []
        do {
            for zone in try await sharedDB.allRecordZones() {
                let q = CKQuery(recordType: "Moment", predicate: NSPredicate(value: true))
                let records = try await query(q, in: sharedDB, zone: zone.zoneID, limit: 50)
                for r in records { out.append(try await moment(from: r)) }
            }
        } catch { throw map(error) }
        return FeedPage(items: out.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }

    func contributions(momentID: String) async throws -> [Contribution] {
        let (record, db) = try await momentRecord(id: momentID)
        let q = CKQuery(recordType: "Contribution", predicate: NSPredicate(format: "momentRef == %@", CKRecord.Reference(recordID: record.recordID, action: .deleteSelf)))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let records = try await query(q, in: db, zone: record.recordID.zoneID, limit: 500)
        var out: [Contribution] = []
        for r in records { out.append(try await Self.contribution(from: r, media: media)) }
        return out
    }

    func addContribution(_ c: Contribution, mediaData: Data?) async throws -> Contribution {
        let (momentRecord, db) = try await momentRecord(id: c.momentID)
        guard (momentRecord["allowsContributions"] as? Int ?? 1) == 1 else { throw SocialError.notAllowed }
        let record = CKRecord(recordType: "Contribution", recordID: CKRecord.ID(recordName: "contrib_\(c.id)", zoneID: momentRecord.recordID.zoneID))
        record["momentRef"] = CKRecord.Reference(recordID: momentRecord.recordID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: momentRecord.recordID, action: .none)
        record["authorID"] = c.authorID
        record["authorName"] = c.authorName
        record["kind"] = c.kind.rawValue
        record["caption"] = c.caption
        record["originalTimestamp"] = c.originalTimestamp
        if let mediaData, let url = try? Self.tempFile(mediaData, ext: c.kind == .video ? "mp4" : c.kind == .voice ? "m4a" : "jpg") { record["media"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: db)
        // Counters live on the root so the feed never has to count children.
        momentRecord["contributionCount"] = (momentRecord["contributionCount"] as? Int ?? 0) + 1
        if mediaData != nil { momentRecord["mediaCount"] = (momentRecord["mediaCount"] as? Int ?? 0) + 1 }
        var members = momentRecord["memberIDs"] as? [String] ?? []
        var names = momentRecord["memberNames"] as? [String] ?? []
        if !members.contains(c.authorID) { members.append(c.authorID); names.append(c.authorName); momentRecord["memberIDs"] = members; momentRecord["memberNames"] = names }
        _ = try? await save(momentRecord, in: db)
        var result = try await Self.contribution(from: saved, media: media)
        result.uploadState = .uploaded
        return result
    }

    func removeContribution(id: String, momentID: String) async throws {
        let (momentRecord, db) = try await momentRecord(id: momentID)
        do { try await db.deleteRecord(withID: CKRecord.ID(recordName: "contrib_\(id)", zoneID: momentRecord.recordID.zoneID)) } catch { throw map(error) }
        momentRecord["contributionCount"] = max(0, (momentRecord["contributionCount"] as? Int ?? 1) - 1)
        _ = try? await save(momentRecord, in: db)
    }

    func share(momentID: String, with userIDs: [String]) async throws -> URL {
        let (record, db) = try await momentRecord(id: momentID)
        guard db === privateDB else { throw SocialError.notAllowed }
        let share: CKShare
        if let existingRef = record.share, let existing = try? await privateDB.record(for: existingRef.recordID) as? CKShare {
            share = existing
        } else {
            share = CKShare(rootRecord: record)
            share[CKShare.SystemFieldKey.title] = record["title"] as? String
            // Invite-only: only people the owner adds (through the system sharing UI) can open it.
            share.publicPermission = .none
        }
        // Direct invites: look the people up by their user record and add them as read-write participants.
        for uid in userIDs {
            guard !share.participants.contains(where: { $0.userIdentity.userRecordID?.recordName == uid }) else { continue }
            guard (try? await audienceAllows("addAudience", ownerID: uid)) ?? true else { continue }
            if let p = try? await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: uid)) { p.permission = .readWrite; share.addParticipant(p) }
        }
        do {
            _ = try await privateDB.modifyRecords(saving: [record, share], deleting: [])
        } catch { throw map(error) }
        if !userIDs.isEmpty {
            var members = record["memberIDs"] as? [String] ?? []
            var names = record["memberNames"] as? [String] ?? []
            for uid in userIDs where !members.contains(uid) {
                members.append(uid); names.append((try? await user(id: uid).displayName) ?? "Someone")
            }
            record["memberIDs"] = members; record["memberNames"] = names
        }
        record["shareCount"] = (record["shareCount"] as? Int ?? 0) + 1
        _ = try? await save(record, in: privateDB)
        guard let url = share.url else { throw SocialError.backend("iCloud didn't return a share link yet. Try again.") }
        return url
    }

    /// The CKShare for a Moment, for the system sharing controller (add people, manage access).
    func shareRecord(momentID: String) async throws -> (CKShare, CKRecord) {
        let (record, _) = try await momentRecord(id: momentID)
        if let ref = record.share, let share = try? await privateDB.record(for: ref.recordID) as? CKShare { return (share, record) }
        _ = try await share(momentID: momentID, with: [])
        let (again, _) = try await momentRecord(id: momentID)
        guard let ref = again.share, let share = try await privateDB.record(for: ref.recordID) as? CKShare else { throw SocialError.backend("Share not ready.") }
        return (share, again)
    }

    func acceptInvite(url: URL) async throws -> SocialMoment {
        do {
            let metadata = try await container.shareMetadata(for: url)
            return try await accept(metadata)
        } catch { throw map(error) }
    }

    func accept(_ metadata: CKShare.Metadata) async throws -> SocialMoment {
        do {
            _ = try await container.accept(metadata)
            guard let rootID = metadata.hierarchicalRootRecordID else { throw SocialError.notFound }
            let record = try await sharedDB.record(for: rootID)
            let moment = try await moment(from: record)
            // Join as a member so "you were there" and counts are right for everyone.
            let me = try await currentUser()
            var members = record["memberIDs"] as? [String] ?? []
            if !members.contains(me.id) {
                members.append(me.id)
                record["memberIDs"] = members
                record["memberNames"] = (record["memberNames"] as? [String] ?? []) + [me.displayName]
                _ = try? await save(record, in: sharedDB)
            }
            return moment
        } catch { throw map(error) }
    }

    func leaveMoment(id: String) async throws {
        let (record, db) = try await momentRecord(id: id)
        guard db === sharedDB, let shareRef = record.share else { throw SocialError.notAllowed }
        do { try await sharedDB.deleteRecord(withID: shareRef.recordID) } catch { throw map(error) }
    }

    /// Joining without an invite only works for public Moments (the public mirror is world-writable
    /// once the "Authenticated" role has write access in the CloudKit Dashboard). Private/friends
    /// Moments need a share link — CloudKit enforces that server-side.
    func join(momentID: String) async throws -> SocialMoment {
        let (record, db) = try await momentRecord(id: momentID)
        let me = try await currentUser()
        guard db === publicDB || db === sharedDB else { return try await moment(from: record) }
        var members = record["memberIDs"] as? [String] ?? []
        if !members.contains(me.id) {
            members.append(me.id); record["memberIDs"] = members
            record["memberNames"] = (record["memberNames"] as? [String] ?? []) + [me.displayName]
            _ = try await save(record, in: db)
        }
        return try await moment(from: record)
    }

    func merge(sourceID: String, into targetID: String) async throws -> SocialMoment {
        let (src, sdb) = try await momentRecord(id: sourceID)
        let (dst, ddb) = try await momentRecord(id: targetID)
        guard sdb === privateDB, ddb === privateDB else { throw SocialError.notAllowed }
        // Re-point children: CloudKit records can't change zone/parent in place, so copy then delete.
        let q = CKQuery(recordType: "Contribution", predicate: NSPredicate(format: "momentRef == %@", CKRecord.Reference(recordID: src.recordID, action: .deleteSelf)))
        let children = try await query(q, in: privateDB, zone: src.recordID.zoneID, limit: 500)
        var copies: [CKRecord] = []
        for c in children {
            let copy = CKRecord(recordType: "Contribution", recordID: CKRecord.ID(recordName: c.recordID.recordName + "-m", zoneID: dst.recordID.zoneID))
            for key in c.allKeys() where key != "momentRef" { copy[key] = c[key] }
            copy["momentRef"] = CKRecord.Reference(recordID: dst.recordID, action: .deleteSelf)
            copy.parent = CKRecord.Reference(recordID: dst.recordID, action: .none)
            copies.append(copy)
        }
        dst["contributionCount"] = (dst["contributionCount"] as? Int ?? 0) + (src["contributionCount"] as? Int ?? 0)
        dst["mediaCount"] = (dst["mediaCount"] as? Int ?? 0) + (src["mediaCount"] as? Int ?? 0)
        var members = dst["memberIDs"] as? [String] ?? [], names = dst["memberNames"] as? [String] ?? []
        for (id, n) in zip(src["memberIDs"] as? [String] ?? [], src["memberNames"] as? [String] ?? []) where !members.contains(id) { members.append(id); names.append(n) }
        dst["memberIDs"] = members; dst["memberNames"] = names
        do { _ = try await privateDB.modifyRecords(saving: copies + [dst], deleting: [src.recordID]) } catch { throw map(error) }
        return try await moment(from: dst)
    }

    func setCover(momentID: String, data: Data) async throws -> SocialMoment {
        let (record, db) = try await momentRecord(id: momentID)
        guard db === privateDB else { throw SocialError.notAllowed }
        if let url = try? Self.tempFile(data, ext: "jpg") { record["cover"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: db)
        coverCache[record.recordID.recordName + "/cover"] = nil
        return try await moment(from: saved)
    }

    // MARK: - Feed / Discover

    func feed(cursor: String?) async throws -> FeedPage<SocialMoment> {
        async let mine = myMoments(cursor: nil)
        async let shared = sharedWithMe(cursor: nil)
        var items = try await mine.items + shared.items
        // Public Moments from people I follow.
        let followingIDs = (try? await following().map(\.toID)) ?? []
        if !followingIDs.isEmpty {
            let q = CKQuery(recordType: "PublicMoment", predicate: NSPredicate(format: "creatorID IN %@", Array(followingIDs.prefix(100))))
            q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let records = try? await query(q, in: publicDB, limit: 50) {
                for r in records { if let m = try? await moment(from: r), !items.contains(where: { $0.id == m.id }) { items.append(m) } }
            }
        }
        return FeedPage(items: items, cursor: nil)
    }

    func discover(query text: String?, place: String?, cursor: String?) async throws -> FeedPage<SocialMoment> {
        var predicates: [NSPredicate] = []
        if let text, !text.isBlank { predicates.append(NSPredicate(format: "self CONTAINS %@", text)) }
        if let place, !place.isBlank { predicates.append(NSPredicate(format: "coarsePlace == %@", place)) }
        let predicate = predicates.isEmpty ? NSPredicate(value: true) : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let q = CKQuery(recordType: "PublicMoment", predicate: predicate)
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (records, next) = try await queryPage(q, in: publicDB, cursor: cursor, limit: 30)
        var out: [SocialMoment] = []
        for r in records { if let m = try? await moment(from: r) { out.append(m) } }
        return FeedPage(items: out, cursor: next)
    }

    /// Public Moments carry the venue as a CLLocation so CloudKit can answer "within 2 km of here".
    func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [SocialMoment] {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let q = CKQuery(recordType: "PublicMoment", predicate: NSPredicate(format: "distanceToLocation:fromLocation:(location, %@) < %f", here, radiusKm * 1000))
        q.sortDescriptors = [CKLocationSortDescriptor(key: "location", relativeLocation: here)]
        var out: [SocialMoment] = []
        for r in try await query(q, in: publicDB, limit: 60) { if let m = try? await moment(from: r) { out.append(m) } }
        return out
    }

    func nowNearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [NowPost] {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let q = CKQuery(recordType: "Now", predicate: NSPredicate(format: "distanceToLocation:fromLocation:(location, %@) < %f AND expiresAt > %@ AND discoverable == 1", here, radiusKm * 1000, Date.now as NSDate))
        q.sortDescriptors = [CKLocationSortDescriptor(key: "location", relativeLocation: here)]
        return try await query(q, in: publicDB, limit: 60).map { Self.now(from: $0) }
    }

    func moments(atPlace placeID: String) async throws -> [SocialMoment] {
        let q = CKQuery(recordType: "PublicMoment", predicate: NSPredicate(format: "placeID == %@", placeID))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [SocialMoment] = []
        for r in try await query(q, in: publicDB, limit: 100) { if let m = try? await moment(from: r) { out.append(m) } }
        return out
    }

    // Claims live in the public DB, one record per place; `verified` is only ever set from the Dashboard.
    func claim(for placeID: String) async throws -> PlaceClaim? {
        guard let r = try? await publicDB.record(for: CKRecord.ID(recordName: "claim_\(placeID)")) else { return nil }
        return Self.claim(from: r)
    }
    func saveClaim(_ c: PlaceClaim) async throws -> PlaceClaim {
        let me = try await currentUser()
        let id = CKRecord.ID(recordName: "claim_\(c.placeID)")
        let r = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "PlaceClaim", recordID: id)
        if let owner = r["ownerID"] as? String, owner != me.id { throw SocialError.notAllowed }
        r["placeID"] = c.placeID; r["ownerID"] = me.id; r["ownerName"] = me.displayName
        r["businessName"] = c.businessName; r["role"] = c.role; r["note"] = c.note
        if r["verified"] == nil { r["verified"] = 0 }
        return Self.claim(from: try await save(r, in: publicDB))
    }
    func myClaims() async throws -> [PlaceClaim] {
        let me = try await currentUser()
        return try await query(CKQuery(recordType: "PlaceClaim", predicate: NSPredicate(format: "ownerID == %@", me.id)), in: publicDB, limit: 50).map(Self.claim(from:))
    }
    static func claim(from r: CKRecord) -> PlaceClaim {
        PlaceClaim(id: r["placeID"] as? String ?? "", placeID: r["placeID"] as? String ?? "", ownerID: r["ownerID"] as? String ?? "", ownerName: r["ownerName"] as? String ?? "", businessName: r["businessName"] as? String ?? "", role: r["role"] as? String ?? "", note: r["note"] as? String ?? "", verified: (r["verified"] as? Int ?? 0) == 1, createdAt: r.creationDate ?? .now)
    }

    // MARK: - Creator economy (public DB records; access to paid sides is a CKShare the creator's phone grants)

    private var subscribedCreators: Set<String> = []

    func creatorPlan(for userID: String) async throws -> CreatorPlan? {
        guard let r = try? await publicDB.record(for: CKRecord.ID(recordName: "plan_\(userID)")) else { return nil }
        return Self.plan(from: r)
    }
    func saveCreatorPlan(_ plan: CreatorPlan) async throws -> CreatorPlan {
        let me = try await currentUser()
        let id = CKRecord.ID(recordName: "plan_\(me.id)")
        let r = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "CreatorPlan", recordID: id)
        r["creatorID"] = me.id; r["creatorName"] = me.displayName; r["title"] = plan.title; r["pitch"] = plan.pitch; r["tier"] = plan.tier.rawValue
        r["perks"] = plan.perks; r["payoutHint"] = plan.payoutHint
        return Self.plan(from: try await save(r, in: publicDB))
    }
    func removeCreatorPlan() async throws {
        let me = try await currentUser()
        _ = try? await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "plan_\(me.id)"))
    }
    func subscribe(to creatorID: String, tier: CreatorPlan.Tier, transactionID: String?, days: Int) async throws -> CreatorSubscription {
        let me = try await currentUser()
        guard creatorID != me.id, (try await creatorPlan(for: creatorID)) != nil else { throw SocialError.notAllowed }
        let id = CKRecord.ID(recordName: "sub_\(me.id)_\(creatorID)")
        let r = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "CreatorSubscription", recordID: id)
        let previous = r["expiresAt"] as? Date
        let start = (previous ?? .distantPast) > .now ? previous! : Date.now
        r["subscriberID"] = me.id; r["subscriberName"] = me.displayName; r["creatorID"] = creatorID; r["tier"] = tier.rawValue
        r["startedAt"] = Date.now; r["expiresAt"] = start.addingTimeInterval(Double(days) * 86400); r["transactionID"] = transactionID
        let saved = try await save(r, in: publicDB)
        subscribedCreators.insert(creatorID)
        return Self.subscription(from: saved)
    }
    func mySubscriptions() async throws -> [CreatorSubscription] {
        let me = try await currentUser()
        let subs = try await query(CKQuery(recordType: "CreatorSubscription", predicate: NSPredicate(format: "subscriberID == %@", me.id)), in: publicDB, limit: 200).map(Self.subscription(from:))
        subscribedCreators = Set(subs.filter(\.isActive).map(\.creatorID))
        return subs.sorted { $0.expiresAt > $1.expiresAt }
    }
    func subscribers() async throws -> [CreatorSubscription] {
        let me = try await currentUser()
        let subs = try await query(CKQuery(recordType: "CreatorSubscription", predicate: NSPredicate(format: "creatorID == %@", me.id)), in: publicDB, limit: 500).map(Self.subscription(from:))
        // The creator's phone is what lets paying people in: add every active subscriber to every paid Moment's share.
        for m in (try? await myMoments(cursor: nil).items.filter { $0.visibility == .subscribers }) ?? [] { try? await grantSubscribers(momentID: m.id, to: subs) }
        return subs.sorted { $0.startedAt > $1.startedAt }
    }
    private func grantSubscribers(momentID: String, to subs: [CreatorSubscription]? = nil) async throws {
        let list: [CreatorSubscription]
        if let subs { list = subs } else { list = try await subscribers() }
        let ids = list.filter(\.isActive).map(\.subscriberID)
        if !ids.isEmpty { _ = try? await share(momentID: momentID, with: ids) }
    }
    func tip(creatorID: String, momentID: String?, amount: CreatorTip.Amount, note: String, transactionID: String?) async throws -> CreatorTip {
        let me = try await currentUser()
        guard creatorID != me.id, (try await creatorPlan(for: creatorID)) != nil else { throw SocialError.notAllowed }
        let r = CKRecord(recordType: "CreatorTip", recordID: CKRecord.ID(recordName: "tip_\(UUID().uuidString)"))
        r["fromID"] = me.id; r["fromName"] = me.displayName; r["creatorID"] = creatorID; r["momentID"] = momentID; r["amount"] = amount.rawValue; r["note"] = note; r["transactionID"] = transactionID
        return Self.tip(from: try await save(r, in: publicDB))
    }
    func tips() async throws -> [CreatorTip] {
        let me = try await currentUser()
        let q = CKQuery(recordType: "CreatorTip", predicate: NSPredicate(format: "creatorID == %@", me.id)); q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return try await query(q, in: publicDB, limit: 500).map(Self.tip(from:))
    }
    static func tip(from r: CKRecord) -> CreatorTip {
        CreatorTip(id: r.recordID.recordName, fromID: r["fromID"] as? String ?? "", fromName: r["fromName"] as? String ?? "", creatorID: r["creatorID"] as? String ?? "", momentID: r["momentID"] as? String, amount: CreatorTip.Amount(rawValue: r["amount"] as? String ?? "") ?? .small, note: r["note"] as? String ?? "", createdAt: r.creationDate ?? .now, transactionID: r["transactionID"] as? String)
    }
    static func plan(from r: CKRecord) -> CreatorPlan {
        CreatorPlan(creatorID: r["creatorID"] as? String ?? "", creatorName: r["creatorName"] as? String ?? "", title: r["title"] as? String ?? "", pitch: r["pitch"] as? String ?? "", tier: CreatorPlan.Tier(rawValue: r["tier"] as? String ?? "") ?? .t1, perks: r["perks"] as? [String] ?? [], payoutHint: r["payoutHint"] as? String ?? "", createdAt: r.creationDate ?? .now)
    }
    static func subscription(from r: CKRecord) -> CreatorSubscription {
        CreatorSubscription(id: r.recordID.recordName, subscriberID: r["subscriberID"] as? String ?? "", subscriberName: r["subscriberName"] as? String ?? "", creatorID: r["creatorID"] as? String ?? "", tier: CreatorPlan.Tier(rawValue: r["tier"] as? String ?? "") ?? .t1, startedAt: r["startedAt"] as? Date ?? .now, expiresAt: r["expiresAt"] as? Date ?? .now, transactionID: r["transactionID"] as? String)
    }

    static func write(place: SocialPlace?, to r: CKRecord) {
        r["placeID"] = place?.id; r["placeName"] = place?.name; r["placeArea"] = place?.area; r["placeCategory"] = place?.category
        r["location"] = place.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    static func place(from r: CKRecord) -> SocialPlace? {
        guard let id = r["placeID"] as? String, let name = r["placeName"] as? String, let loc = r["location"] as? CLLocation else { return nil }
        return SocialPlace(id: id, name: name, area: r["placeArea"] as? String ?? "", latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, category: r["placeCategory"] as? String)
    }

    static func now(from r: CKRecord) -> NowPost {
        NowPost(id: r.recordID.recordName, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: nil, createdAt: r.creationDate ?? .now, expiresAt: r["expiresAt"] as? Date ?? .now, coarsePlace: r["coarsePlace"] as? String, savedToMomentID: nil, activity: NowPost.Activity(rawValue: r["activity"] as? String ?? "") ?? .none, place: place(from: r), joinerIDs: r["joinerIDs"] as? [String] ?? [], joinerNames: r["joinerNames"] as? [String] ?? [])
    }

    private func mirrorPublic(_ moment: SocialMoment, record: CKRecord) async throws {
        let id = CKRecord.ID(recordName: "public_\(moment.id)")
        let pub = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "PublicMoment", recordID: id)
        for key in ["creatorID", "creatorName", "title", "description", "startAt", "endAt", "locationName", "coarsePlace", "memberIDs", "memberNames", "contributionCount", "mediaCount", "commentCount", "shareCount", "isLive", "templateID", "remixedFromID", "placeID", "placeName", "placeArea", "placeCategory", "location", "signature", "creatorPublicKey", "signedAt"] { pub[key] = record[key] }
        // Subscribers-only Moments are listed publicly as a locked preview (cover + title); their sides stay in the
        // creator's private zone and reach subscribers through the CKShare the creator's phone grants them.
        pub["visibility"] = moment.visibility == .subscribers ? MomentVisibility.subscribers.rawValue : MomentVisibility.publicAll.rawValue
        pub["sourceID"] = moment.id
        if let cover = record["cover"] as? CKAsset, let url = cover.fileURL { pub["cover"] = CKAsset(fileURL: url) }
        _ = try await save(pub, in: publicDB)
    }

    // MARK: - Engagement

    func comments(momentID: String) async throws -> [MomentComment] {
        let (record, db) = try await momentRecord(id: momentID)
        let q = CKQuery(recordType: "Comment", predicate: NSPredicate(format: "momentRef == %@", CKRecord.Reference(recordID: record.recordID, action: .deleteSelf)))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return try await query(q, in: db, zone: record.recordID.zoneID, limit: 500).map { r in
            MomentComment(id: r.recordID.recordName, momentID: momentID, contributionID: r["contributionID"] as? String, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", createdAt: r.creationDate ?? .now)
        }
    }

    /// Reads the owner's public audience rule and checks it against my relationship with them.
    private func audienceAllows(_ key: String, ownerID: String) async throws -> Bool {
        let me = try await currentUser()
        if ownerID == me.id { return true }
        guard let profile = try? await publicDB.record(for: CKRecord.ID(recordName: "profile_\(ownerID)")) else { return true }
        switch SafetySettings.Audience(rawValue: profile[key] as? String ?? "") ?? .friends {
        case .everyone: return true
        case .nobody: return false
        case .friends:
            let a = try? await publicDB.record(for: CKRecord.ID(recordName: "follow_\(me.id)_\(ownerID)"))
            let b = try? await publicDB.record(for: CKRecord.ID(recordName: "follow_\(ownerID)_\(me.id)"))
            return a != nil && b != nil
        }
    }

    func addComment(_ c: MomentComment) async throws -> MomentComment {
        guard ContentModeration.check(c.text) == .ok else { throw SocialError.notAllowed }
        let (momentRecord, db) = try await momentRecord(id: c.momentID)
        guard try await audienceAllows("commentAudience", ownerID: momentRecord["creatorID"] as? String ?? "") else { throw SocialError.notAllowed }
        let record = CKRecord(recordType: "Comment", recordID: CKRecord.ID(recordName: "comment_\(c.id)", zoneID: momentRecord.recordID.zoneID))
        record["momentRef"] = CKRecord.Reference(recordID: momentRecord.recordID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: momentRecord.recordID, action: .none)
        record["contributionID"] = c.contributionID
        record["authorID"] = c.authorID
        record["authorName"] = c.authorName
        record["text"] = c.text
        let saved = try await save(record, in: db)
        momentRecord["commentCount"] = (momentRecord["commentCount"] as? Int ?? 0) + 1
        _ = try? await save(momentRecord, in: db)
        var out = c; out.id = saved.recordID.recordName; out.createdAt = saved.creationDate ?? .now
        return out
    }

    func deleteComment(id: String, momentID: String) async throws {
        let (momentRecord, db) = try await momentRecord(id: momentID)
        do { try await db.deleteRecord(withID: CKRecord.ID(recordName: id, zoneID: momentRecord.recordID.zoneID)) } catch { throw map(error) }
    }

    func react(momentID: String, contributionID: String?, kind: ReactionKind?) async throws {
        let (momentRecord, db) = try await momentRecord(id: momentID)
        let me = try await currentUser()
        let recordID = CKRecord.ID(recordName: "reaction_\(me.id)_\(contributionID ?? "moment")", zoneID: momentRecord.recordID.zoneID)
        if let kind {
            let record = (try? await db.record(for: recordID)) ?? CKRecord(recordType: "Reaction", recordID: recordID)
            record["momentRef"] = CKRecord.Reference(recordID: momentRecord.recordID, action: .deleteSelf)
            record.parent = CKRecord.Reference(recordID: momentRecord.recordID, action: .none)
            record["contributionID"] = contributionID
            record["authorID"] = me.id
            record["kind"] = kind.rawValue
            _ = try await save(record, in: db)
        } else {
            do { try await db.deleteRecord(withID: recordID) } catch { throw map(error) }
        }
    }

    func myReactions(momentID: String) async throws -> [MomentReaction] {
        let (momentRecord, db) = try await momentRecord(id: momentID)
        let me = try await currentUser()
        let q = CKQuery(recordType: "Reaction", predicate: NSPredicate(format: "momentRef == %@ AND authorID == %@", CKRecord.Reference(recordID: momentRecord.recordID, action: .deleteSelf), me.id))
        return try await query(q, in: db, zone: momentRecord.recordID.zoneID, limit: 200).compactMap { r in
            guard let kind = ReactionKind(rawValue: r["kind"] as? String ?? "") else { return nil }
            return MomentReaction(id: r.recordID.recordName, momentID: momentID, contributionID: r["contributionID"] as? String, authorID: me.id, kind: kind, createdAt: r.creationDate ?? .now)
        }
    }

    // MARK: - NOW

    func postNow(_ post: NowPost, mediaData: Data?) async throws -> NowPost {
        guard ContentModeration.check(post.text) == .ok else { throw SocialError.notAllowed }
        let record = CKRecord(recordType: "Now", recordID: CKRecord.ID(recordName: "now_\(post.id)"))
        record["authorID"] = post.authorID
        record["authorName"] = post.authorName
        record["text"] = post.text
        record["expiresAt"] = post.expiresAt
        record["coarsePlace"] = post.coarsePlace
        record["activity"] = post.activity.rawValue
        record["joinerIDs"] = post.joinerIDs; record["joinerNames"] = post.joinerNames
        Self.write(place: post.place, to: record)
        record["discoverable"] = ((try? await safetySettings())?.allowDiscoverByLocation ?? false) ? 1 : 0
        if let mediaData, let url = try? Self.tempFile(mediaData, ext: "jpg") { record["media"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: publicDB)
        var out = post; out.id = saved.recordID.recordName
        return out
    }

    func joinNow(id: String) async throws -> NowPost {
        let me = try await currentUser()
        guard let r = try? await publicDB.record(for: CKRecord.ID(recordName: id)) else { throw SocialError.notFound }
        var ids = r["joinerIDs"] as? [String] ?? [], names = r["joinerNames"] as? [String] ?? []
        if !ids.contains(me.id) { ids.append(me.id); names.append(me.displayName); r["joinerIDs"] = ids; r["joinerNames"] = names; _ = try await save(r, in: publicDB) }
        return NowPost(id: id, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: nil, createdAt: r.creationDate ?? .now, expiresAt: r["expiresAt"] as? Date ?? .now, coarsePlace: r["coarsePlace"] as? String, savedToMomentID: nil, activity: NowPost.Activity(rawValue: r["activity"] as? String ?? "") ?? .none, joinerIDs: ids, joinerNames: names)
    }

    func nowFeed() async throws -> [NowPost] {
        let me = try await currentUser()
        var ids = (try? await following().map(\.toID)) ?? []
        ids.append(me.id)
        let q = CKQuery(recordType: "Now", predicate: NSPredicate(format: "authorID IN %@ AND expiresAt > %@", Array(ids.prefix(100)), Date.now as NSDate))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [NowPost] = []
        for r in try await query(q, in: publicDB, limit: 100) {
            var ref: MediaRef? = nil
            if let asset = r["media"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url), let local = try? await media.store(data, extension: "jpg") { ref = MediaRef(kind: .photo, localRef: local, remoteID: r.recordID.recordName) }
            out.append(NowPost(id: r.recordID.recordName, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: ref, createdAt: r.creationDate ?? .now, expiresAt: r["expiresAt"] as? Date ?? .now, coarsePlace: r["coarsePlace"] as? String, savedToMomentID: nil, activity: NowPost.Activity(rawValue: r["activity"] as? String ?? "") ?? .none, joinerIDs: r["joinerIDs"] as? [String] ?? [], joinerNames: r["joinerNames"] as? [String] ?? []))
        }
        return out
    }

    func deleteNow(id: String) async throws {
        do { try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: id)) } catch { throw map(error) }
    }

    // MARK: - Graph & safety

    func follow(userID: String, close: Bool) async throws {
        let me = try await currentUser()
        let record = CKRecord(recordType: "Follow", recordID: CKRecord.ID(recordName: "follow_\(me.id)_\(userID)"))
        record["fromID"] = me.id; record["toID"] = userID; record["isClose"] = close ? 1 : 0
        _ = try await save(record, in: publicDB)
    }

    func unfollow(userID: String) async throws {
        let me = try await currentUser()
        do { try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "follow_\(me.id)_\(userID)")) } catch { throw map(error) }
    }

    func following() async throws -> [Follow] {
        let me = try await currentUser()
        let q = CKQuery(recordType: "Follow", predicate: NSPredicate(format: "fromID == %@", me.id))
        return try await query(q, in: publicDB, limit: 500).map { Follow(fromID: me.id, toID: $0["toID"] as? String ?? "", createdAt: $0.creationDate ?? .now, isClose: ($0["isClose"] as? Int ?? 0) == 1) }
    }

    func followers() async throws -> [Follow] {
        let me = try await currentUser()
        let q = CKQuery(recordType: "Follow", predicate: NSPredicate(format: "toID == %@", me.id))
        return try await query(q, in: publicDB, limit: 500).map { Follow(fromID: $0["fromID"] as? String ?? "", toID: me.id, createdAt: $0.creationDate ?? .now, isClose: false) }
    }

    func block(userID: String) async throws { try await setFlag("Block", userID: userID, on: true); try? await unfollow(userID: userID) }
    func unblock(userID: String) async throws { try await setFlag("Block", userID: userID, on: false) }
    func blockedUserIDs() async throws -> [String] { try await flagged("Block") }
    func mute(userID: String) async throws { try await setFlag("Mute", userID: userID, on: true) }
    func mutedUserIDs() async throws -> [String] { try await flagged("Mute") }

    private func setFlag(_ type: String, userID: String, on: Bool) async throws {
        let id = CKRecord.ID(recordName: "\(type.lowercased())_\(userID)")
        if on {
            let r = CKRecord(recordType: type, recordID: id); r["userID"] = userID
            _ = try await save(r, in: privateDB)
        } else {
            do { try await privateDB.deleteRecord(withID: id) } catch { throw map(error) }
        }
    }
    private func flagged(_ type: String) async throws -> [String] {
        try await query(CKQuery(recordType: type, predicate: NSPredicate(value: true)), in: privateDB, limit: 500).compactMap { $0["userID"] as? String }
    }

    func report(_ report: UserReport) async throws {
        let r = CKRecord(recordType: "Report", recordID: CKRecord.ID(recordName: "report_\(report.id)"))
        r["reporterID"] = report.reporterID; r["targetUserID"] = report.targetUserID; r["targetMomentID"] = report.targetMomentID
        r["targetContributionID"] = report.targetContributionID; r["targetCommentID"] = report.targetCommentID
        r["reason"] = report.reason.rawValue; r["details"] = report.details
        _ = try await save(r, in: publicDB)
    }

    func safetySettings() async throws -> SafetySettings {
        let id = CKRecord.ID(recordName: "settings_safety")
        guard let r = try? await privateDB.record(for: id), let data = r["json"] as? Data, let s = try? JSONDecoder().decode(SafetySettings.self, from: data) else { return SafetySettings() }
        return s
    }

    func updateSafetySettings(_ s: SafetySettings) async throws {
        let id = CKRecord.ID(recordName: "settings_safety")
        let r = (try? await privateDB.record(for: id)) ?? CKRecord(recordType: "Settings", recordID: id)
        r["json"] = try JSONEncoder().encode(s)
        _ = try await save(r, in: privateDB)
        // Audience rules other people must respect live on the public profile (they aren't secret).
        if let me = cachedUser {
            let pid = CKRecord.ID(recordName: "profile_\(me.id)")
            if let p = try? await publicDB.record(for: pid) {
                p["privateAccount"] = s.privateAccount ? 1 : 0
                p["commentAudience"] = s.whoCanComment.rawValue
                p["addAudience"] = s.whoCanAddMeToMoments.rawValue
                p["messageAudience"] = s.whoCanMessage.rawValue
                _ = try? await save(p, in: publicDB)
            }
        }
    }

    // MARK: - Inbox

    func activity(cursor: String?) async throws -> FeedPage<ActivityItem> {
        // Derived from shared Moments: recent contributions by others on Moments I'm in.
        let me = try await currentUser()
        var items: [ActivityItem] = []
        for m in (try await sharedWithMe(cursor: nil).items + myMoments(cursor: nil).items).prefix(20) {
            for c in (try? await contributions(momentID: m.id)) ?? [] where c.authorID != me.id && c.createdAt.daysUntil(.now) <= 14 {
                items.append(ActivityItem(id: "act_\(c.id)", kind: .contribution, actorName: c.authorName, momentID: m.id, momentTitle: m.title, text: "\(c.authorName) added \(c.kind == .text ? "a note" : "a \(c.kind.rawValue)") to \(m.title)", createdAt: c.createdAt, read: false))
            }
        }
        return FeedPage(items: items.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }

    func invites() async throws -> [MomentInvite] {
        // CloudKit invitations arrive as share links; once accepted they appear in `sharedWithMe`.
        try await sharedWithMe(cursor: nil).items.map { MomentInvite(id: "inv_\($0.id)", momentID: $0.id, momentTitle: $0.title, inviterID: $0.creatorID, inviterName: $0.creatorName, shareURL: $0.shareURL, createdAt: $0.createdAt, accepted: true) }
    }

    func markActivityRead() async throws {}

    func conversations() async throws -> [Conversation] {
        try await ensureZone()
        var out: [Conversation] = []
        let q = CKQuery(recordType: "Conversation", predicate: NSPredicate(value: true))
        for db in [privateDB, sharedDB] {
            let zones: [CKRecordZone.ID] = db === privateDB ? [zoneID] : ((try? await sharedDB.allRecordZones().map(\.zoneID)) ?? [])
            for z in zones {
                for r in (try? await query(q, in: db, zone: z, limit: 100)) ?? [] {
                    out.append(Conversation(id: r.recordID.recordName, participantIDs: r["participantIDs"] as? [String] ?? [], participantNames: r["participantNames"] as? [String] ?? [], lastMessage: r["lastMessage"] as? String ?? "", updatedAt: r.modificationDate ?? .now, title: r["title"] as? String, emoji: r["emoji"] as? String, groupID: r["groupID"] as? String))
                }
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func messages(conversationID: String) async throws -> [DirectMessage] {
        let (record, db) = try await anyRecord(name: conversationID, type: "Conversation")
        let q = CKQuery(recordType: "Message", predicate: NSPredicate(format: "conversationRef == %@", CKRecord.Reference(recordID: record.recordID, action: .deleteSelf)))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var out: [DirectMessage] = []
        for r in try await query(q, in: db, zone: record.recordID.zoneID, limit: 500) {
            var ref: MediaRef? = nil
            let kind = MediaRef.Kind(rawValue: r["mediaKind"] as? String ?? "") ?? .photo
            if let asset = r["media"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url), let local = try? await media.store(data, extension: kind == .voice ? "m4a" : "jpg") { ref = MediaRef(kind: kind, localRef: local, remoteID: r.recordID.recordName, durationSeconds: r["mediaDuration"] as? Double) }
            out.append(DirectMessage(id: r.recordID.recordName, conversationID: conversationID, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: ref, momentID: r["momentID"] as? String, createdAt: r.creationDate ?? .now, replyToID: r["replyToID"] as? String))
        }
        return out
    }

    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage {
        guard ContentModeration.check(message.text) == .ok else { throw SocialError.notAllowed }
        let (conv, db) = try await anyRecord(name: message.conversationID, type: "Conversation")
        let r = CKRecord(recordType: "Message", recordID: CKRecord.ID(recordName: "msg_\(message.id)", zoneID: conv.recordID.zoneID))
        r["conversationRef"] = CKRecord.Reference(recordID: conv.recordID, action: .deleteSelf)
        r.parent = CKRecord.Reference(recordID: conv.recordID, action: .none)
        r["authorID"] = message.authorID; r["authorName"] = message.authorName; r["text"] = message.text; r["momentID"] = message.momentID; r["replyToID"] = message.replyToID
        r["mediaKind"] = message.media?.kind.rawValue; r["mediaDuration"] = message.media?.durationSeconds
        if let mediaData, let url = try? Self.tempFile(mediaData, ext: message.media?.kind == .voice ? "m4a" : "jpg") { r["media"] = CKAsset(fileURL: url) }
        let saved = try await save(r, in: db)
        if !message.isReaction { conv["lastMessage"] = message.text.isEmpty ? (message.momentID != nil ? "Shared a Moment" : "Photo") : message.text; _ = try? await save(conv, in: db) }
        var out = message; out.id = saved.recordID.recordName
        return out
    }

    /// A 1:1 conversation is a shared record: created in my zone and shared to the other person.
    func conversation(with userID: String) async throws -> Conversation {
        try await ensureZone()
        let me = try await currentUser()
        if let existing = try await conversations().first(where: { Set($0.participantIDs) == Set([me.id, userID]) }) { return existing }
        guard try await audienceAllows("messageAudience", ownerID: userID) else { throw SocialError.notAllowed }
        let other = try await user(id: userID)
        let r = CKRecord(recordType: "Conversation", recordID: CKRecord.ID(recordName: "conv_\(UUID().uuidString)", zoneID: zoneID))
        r["participantIDs"] = [me.id, userID]; r["participantNames"] = [me.displayName, other.displayName]; r["lastMessage"] = ""
        let share = CKShare(rootRecord: r)
        share.publicPermission = .none
        let part = try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: userID))
        part.permission = .readWrite
        share.addParticipant(part)
        do { _ = try await privateDB.modifyRecords(saving: [r, share], deleting: []) } catch { throw map(error) }
        return Conversation(id: r.recordID.recordName, participantIDs: [me.id, userID], participantNames: [me.displayName, other.displayName], lastMessage: "", updatedAt: .now)
    }
    // MARK: - Meet (public DB: opted-in profiles; likes are records only the two people query)
    func datingProfile(for userID: String) async throws -> DatingProfile? {
        guard let r = try? await publicDB.record(for: CKRecord.ID(recordName: "dating_\(userID)")) else { return nil }
        return Self.dating(from: r)
    }
    func saveDatingProfile(_ p: DatingProfile) async throws -> DatingProfile {
        let me = try await currentUser()
        let id = CKRecord.ID(recordName: "dating_\(me.id)")
        let r = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "DatingProfile", recordID: id)
        r["userID"] = me.id; r["displayName"] = me.displayName; r["birthYear"] = p.birthYear; r["gender"] = p.gender.rawValue; r["seeking"] = p.seeking.map(\.rawValue); r["intent"] = p.intent.rawValue
        r["prompts"] = try JSONEncoder().encode(p.prompts); r["photoIDs"] = p.photos.compactMap(\.remoteID); r["bio"] = p.bio; r["hideFromKnown"] = p.hideFromKnown ? 1 : 0; r["overlapOnly"] = p.overlapOnly ? 1 : 0
        return Self.dating(from: try await save(r, in: publicDB))
    }
    func removeDatingProfile() async throws { let me = try await currentUser(); _ = try? await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "dating_\(me.id)")) }
    func datingCandidates() async throws -> [DatingProfile] {
        let me = try await currentUser()
        let q = CKQuery(recordType: "DatingProfile", predicate: NSPredicate(value: true)); q.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        return try await query(q, in: publicDB, limit: 300).map(Self.dating(from:)).filter { $0.userID != me.id }
    }
    func like(userID: String, note: String, promptQuestion: String?) async throws -> DatingLike {
        let me = try await currentUser()
        let r = CKRecord(recordType: "DatingLike", recordID: CKRecord.ID(recordName: "dlike_\(me.id)_\(userID)"))
        r["fromID"] = me.id; r["fromName"] = me.displayName; r["toID"] = userID; r["note"] = note; r["promptQuestion"] = promptQuestion
        let saved = try await save(r, in: publicDB)
        return DatingLike(id: saved.recordID.recordName, fromID: me.id, fromName: me.displayName, toID: userID, note: note, promptQuestion: promptQuestion, createdAt: saved.creationDate ?? .now)
    }
    func pass(userID: String) async throws { var p = Set(UserDefaults.standard.stringArray(forKey: "meet.passed") ?? []); p.insert(userID); UserDefaults.standard.set(Array(p), forKey: "meet.passed") }
    func passedUserIDs() async throws -> [String] { UserDefaults.standard.stringArray(forKey: "meet.passed") ?? [] }
    func likesReceived() async throws -> [DatingLike] {
        let me = try await currentUser()
        return try await query(CKQuery(recordType: "DatingLike", predicate: NSPredicate(format: "toID == %@", me.id)), in: publicDB, limit: 200).map(Self.like(from:))
    }
    func likesSent() async throws -> [DatingLike] {
        let me = try await currentUser()
        return try await query(CKQuery(recordType: "DatingLike", predicate: NSPredicate(format: "fromID == %@", me.id)), in: publicDB, limit: 200).map(Self.like(from:))
    }
    static func dating(from r: CKRecord) -> DatingProfile {
        let prompts = (r["prompts"] as? Data).flatMap { try? JSONDecoder().decode([DatingProfile.Prompt].self, from: $0) } ?? []
        return DatingProfile(userID: r["userID"] as? String ?? "", displayName: r["displayName"] as? String ?? "", birthYear: r["birthYear"] as? Int ?? 2000, gender: DatingProfile.Gender(rawValue: r["gender"] as? String ?? "") ?? .nonBinary, seeking: (r["seeking"] as? [String] ?? []).compactMap(DatingProfile.Gender.init(rawValue:)), intent: DatingProfile.Intent(rawValue: r["intent"] as? String ?? "") ?? .notSure, prompts: prompts, photos: (r["photoIDs"] as? [String] ?? []).map { MediaRef(kind: .photo, localRef: nil, remoteID: $0) }, bio: r["bio"] as? String ?? "", hideFromKnown: (r["hideFromKnown"] as? Int ?? 0) == 1, overlapOnly: (r["overlapOnly"] as? Int ?? 1) == 1, updatedAt: r.modificationDate ?? .now)
    }
    static func like(from r: CKRecord) -> DatingLike {
        DatingLike(id: r.recordID.recordName, fromID: r["fromID"] as? String ?? "", fromName: r["fromName"] as? String ?? "", toID: r["toID"] as? String ?? "", note: r["note"] as? String ?? "", promptQuestion: r["promptQuestion"] as? String, createdAt: r.creationDate ?? .now)
    }

    func markSeen(conversationID: String, lastMessageID: String) async throws {
        let me = try await currentUser()
        let (conv, db) = try await anyRecord(name: conversationID, type: "Conversation")
        let id = CKRecord.ID(recordName: "seen_\(conversationID)_\(me.id)", zoneID: conv.recordID.zoneID)
        let r = (try? await db.record(for: id)) ?? CKRecord(recordType: "Seen", recordID: id)
        if r["conversationRef"] == nil { r["conversationRef"] = CKRecord.Reference(recordID: conv.recordID, action: .deleteSelf); r.parent = CKRecord.Reference(recordID: conv.recordID, action: .none) }
        r["userID"] = me.id; r["lastMessageID"] = lastMessageID
        _ = try await save(r, in: db)
    }
    func seen(conversationID: String) async throws -> [String: String] {
        let (conv, db) = try await anyRecord(name: conversationID, type: "Conversation")
        let q = CKQuery(recordType: "Seen", predicate: NSPredicate(format: "conversationRef == %@", CKRecord.Reference(recordID: conv.recordID, action: .deleteSelf)))
        var out: [String: String] = [:]
        for r in (try? await query(q, in: db, zone: conv.recordID.zoneID, limit: 100)) ?? [] { if let u = r["userID"] as? String, let m = r["lastMessageID"] as? String { out[u] = m } }
        return out
    }
    func setTyping(conversationID: String, typing: Bool) async {}   // no live channel in CloudKit; nothing to send
    func onTyping(_ handler: @escaping @Sendable (String, String) -> Void) async {}
    func conversation(forGroup group: SocialGroup) async throws -> Conversation {
        try await ensureZone()
        let me = try await currentUser()
        if let existing = try await conversations().first(where: { $0.groupID == group.id }) { return existing }
        guard group.ownerID == me.id else { throw SocialError.notFound }   // members receive it through the share once the owner opens it
        let r = CKRecord(recordType: "Conversation", recordID: CKRecord.ID(recordName: "convg_\(group.id)", zoneID: zoneID))
        r["participantIDs"] = group.memberIDs; r["participantNames"] = group.memberNames; r["lastMessage"] = ""; r["title"] = group.name; r["emoji"] = group.emoji; r["groupID"] = group.id
        let share = CKShare(rootRecord: r); share.publicPermission = .none
        for uid in group.memberIDs where uid != me.id { if let p = try? await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: uid)) { p.permission = .readWrite; share.addParticipant(p) } }
        do { _ = try await privateDB.modifyRecords(saving: [r, share], deleting: []) } catch { throw map(error) }
        return Conversation(id: r.recordID.recordName, participantIDs: group.memberIDs, participantNames: group.memberNames, lastMessage: "", updatedAt: .now, title: group.name, emoji: group.emoji, groupID: group.id)
    }

    // MARK: - Groups (a shared record in the owner's zone; members get it in their shared DB)

    func groups() async throws -> [SocialGroup] {
        try await ensureZone()
        var out: [SocialGroup] = []
        let q = CKQuery(recordType: "Group", predicate: NSPredicate(value: true))
        for db in [privateDB, sharedDB] {
            let zones: [CKRecordZone.ID] = db === privateDB ? [zoneID] : ((try? await sharedDB.allRecordZones().map(\.zoneID)) ?? [])
            for z in zones {
                for r in (try? await query(q, in: db, zone: z, limit: 100)) ?? [] {
                    out.append(SocialGroup(id: r.recordID.recordName, ownerID: r["ownerID"] as? String ?? "", name: r["name"] as? String ?? "", emoji: r["emoji"] as? String ?? "👥", memberIDs: r["memberIDs"] as? [String] ?? [], memberNames: r["memberNames"] as? [String] ?? [], conversationID: r["conversationID"] as? String, createdAt: r.creationDate ?? .now))
                }
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    func saveGroup(_ g: SocialGroup) async throws -> SocialGroup {
        try await ensureZone()
        let me = try await currentUser()
        let (existing, db) = (try? await anyRecord(name: g.id, type: "Group")) ?? (CKRecord(recordType: "Group", recordID: CKRecord.ID(recordName: g.id, zoneID: zoneID)), privateDB)
        var out = g
        if existing["ownerID"] == nil { out.ownerID = me.id }
        if !out.memberIDs.contains(out.ownerID) { out.memberIDs.insert(out.ownerID, at: 0); out.memberNames.insert(me.displayName, at: 0) }
        existing["ownerID"] = out.ownerID; existing["name"] = out.name; existing["emoji"] = out.emoji
        existing["memberIDs"] = out.memberIDs; existing["memberNames"] = out.memberNames
        if out.conversationID == nil, out.ownerID == me.id {
            // Group chat: one Conversation record shared to the same people.
            let conv = CKRecord(recordType: "Conversation", recordID: CKRecord.ID(recordName: "conv_\(UUID().uuidString)", zoneID: zoneID))
            conv["participantIDs"] = out.memberIDs; conv["participantNames"] = out.memberNames; conv["lastMessage"] = ""
            let share = CKShare(rootRecord: conv); share.publicPermission = .none
            for uid in out.memberIDs where uid != me.id { if let p = try? await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: uid)) { p.permission = .readWrite; share.addParticipant(p) } }
            do { _ = try await privateDB.modifyRecords(saving: [conv, share], deleting: []) } catch { throw map(error) }
            out.conversationID = conv.recordID.recordName
        }
        existing["conversationID"] = out.conversationID
        if db === privateDB, out.ownerID == me.id {
            let share: CKShare
            if let ref = existing.share, let sh = try? await privateDB.record(for: ref.recordID) as? CKShare { share = sh } else { share = CKShare(rootRecord: existing); share.publicPermission = .none }
            for uid in out.memberIDs where uid != me.id && !share.participants.contains(where: { $0.userIdentity.userRecordID?.recordName == uid }) {
                if let p = try? await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: uid)) { p.permission = .readWrite; share.addParticipant(p) }
            }
            do { _ = try await privateDB.modifyRecords(saving: [existing, share], deleting: []) } catch { throw map(error) }
        } else {
            _ = try await save(existing, in: db)
        }
        return out
    }

    func leaveGroup(id: String) async throws {
        let (record, db) = try await anyRecord(name: id, type: "Group")
        if db === privateDB { do { try await privateDB.deleteRecord(withID: record.recordID) } catch { throw map(error) }; return }
        guard let ref = record.share else { throw SocialError.notAllowed }
        do { try await sharedDB.deleteRecord(withID: ref.recordID) } catch { throw map(error) }
    }

    // MARK: - Collections (private DB, default zone)

    func collections() async throws -> [MomentCollection] {
        let me = try await currentUser()
        let q = CKQuery(recordType: "Collection", predicate: NSPredicate(value: true))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return try await query(q, in: privateDB, limit: 200).map { r in
            MomentCollection(id: r.recordID.recordName, ownerID: me.id, title: r["title"] as? String ?? "", emoji: r["emoji"] as? String ?? "📁", momentIDs: r["momentIDs"] as? [String] ?? [], createdAt: r.creationDate ?? .now)
        }
    }

    func saveCollection(_ c: MomentCollection) async throws -> MomentCollection {
        let id = CKRecord.ID(recordName: c.id)
        let r = (try? await privateDB.record(for: id)) ?? CKRecord(recordType: "Collection", recordID: id)
        r["title"] = c.title; r["emoji"] = c.emoji; r["momentIDs"] = c.momentIDs
        let saved = try await save(r, in: privateDB)
        var out = c; out.createdAt = saved.creationDate ?? c.createdAt
        return out
    }

    func deleteCollection(id: String) async throws {
        do { try await privateDB.deleteRecord(withID: CKRecord.ID(recordName: id)) } catch { throw map(error) }
    }

    // MARK: - Media

    func download(_ ref: MediaRef) async throws -> Data {
        if let local = ref.localRef, let data = try? await media.load(local) { return data }
        throw SocialError.notFound
    }

    // MARK: - Subscriptions (silent push → "Rahul added 8 photos")

    func ensureSubscriptions() async {
        for (db, id) in [(privateDB, "private-changes"), (sharedDB, "shared-changes")] {
            let sub = CKDatabaseSubscription(subscriptionID: id)
            let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
            sub.notificationInfo = info
            _ = try? await db.save(sub)
        }
    }

    // MARK: - Helpers

    private func momentRecord(id: String) async throws -> (CKRecord, CKDatabase) { try await anyRecord(name: id, type: "Moment") }

    private func anyRecord(name: String, type: String) async throws -> (CKRecord, CKDatabase) {
        try await ensureZone()
        if let r = try? await privateDB.record(for: CKRecord.ID(recordName: name, zoneID: zoneID)) { return (r, privateDB) }
        if let zones = try? await sharedDB.allRecordZones() {
            for z in zones { if let r = try? await sharedDB.record(for: CKRecord.ID(recordName: name, zoneID: z.zoneID)) { return (r, sharedDB) } }
        }
        if let r = try? await publicDB.record(for: CKRecord.ID(recordName: "public_\(name)")) { return (r, publicDB) }
        throw SocialError.notFound
    }

    private func save(_ record: CKRecord, in db: CKDatabase) async throws -> CKRecord {
        do { return try await db.save(record) } catch { throw map(error) }
    }

    private func query(_ q: CKQuery, in db: CKDatabase, zone: CKRecordZone.ID? = nil, limit: Int) async throws -> [CKRecord] {
        do {
            let (results, _) = try await db.records(matching: q, inZoneWith: zone, resultsLimit: limit)
            return results.compactMap { try? $0.1.get() }
        } catch { throw map(error) }
    }

    private func queryPage(_ q: CKQuery, in db: CKDatabase, cursor: String?, limit: Int) async throws -> ([CKRecord], String?) {
        do {
            if let cursor, let data = Data(base64Encoded: cursor), let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKQueryOperation.Cursor.self, from: data) {
                let (results, next) = try await db.records(continuingMatchFrom: c, resultsLimit: limit)
                return (results.compactMap { try? $0.1.get() }, next.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true).base64EncodedString() })
            }
            let (results, next) = try await db.records(matching: q, resultsLimit: limit)
            return (results.compactMap { try? $0.1.get() }, next.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true).base64EncodedString() })
        } catch { throw map(error) }
    }

    private func map(_ error: Error) -> Error {
        if let e = error as? SocialError { return e }
        guard let ck = error as? CKError else { return SocialError.backend(error.localizedDescription) }
        switch ck.code {
        case .notAuthenticated: return SocialError.notSignedIn
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return SocialError.offline
        case .unknownItem, .zoneNotFound: return SocialError.notFound
        case .permissionFailure: return SocialError.notAllowed
        case .quotaExceeded: return SocialError.quotaExceeded
        default: return SocialError.backend(ck.localizedDescription)
        }
    }

    static func tempFile(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ck-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func user(from r: CKRecord) -> SocialUser {
        var avatar: MediaRef? = nil
        if let asset = r["avatar"] as? CKAsset, let url = asset.fileURL { avatar = MediaRef(kind: .photo, localRef: nil, remoteID: url.path()) }
        return SocialUser(id: r["userID"] as? String ?? r.recordID.recordName.replacingOccurrences(of: "profile_", with: ""), displayName: r["displayName"] as? String ?? "Someone", handle: r["handle"] as? String ?? "", bio: r["bio"] as? String ?? "", avatarRef: avatar, isPrivateAccount: (r["privateAccount"] as? Int ?? 0) == 1, momentCount: r["momentCount"] as? Int ?? 0, sharedCount: r["sharedCount"] as? Int ?? 0, placeCount: r["placeCount"] as? Int ?? 0, peopleCount: r["peopleCount"] as? Int ?? 0, createdAt: r.creationDate ?? .now, publicKey: r["publicKey"] as? String, momentID: r["momentID"] as? String)
    }

    func moment(from r: CKRecord) async throws -> SocialMoment {
        var cover: MediaRef? = nil
        let coverKey = r.recordID.recordName + "/cover"
        if let cached = coverCache[coverKey] {
            cover = MediaRef(kind: .photo, localRef: cached, remoteID: coverKey)
        } else if let asset = r["cover"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url), let local = try? await media.store(data, extension: "jpg") {
            coverCache[coverKey] = local
            cover = MediaRef(kind: .photo, localRef: local, remoteID: coverKey)
        }
        var shareURL: URL? = nil
        if let shareRef = r.share {
            if let cached = shareURLCache[shareRef.recordID.recordName] { shareURL = cached }
            else if let share = try? await (r.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB).record(for: shareRef.recordID) as? CKShare { shareURL = share.url; shareURLCache[shareRef.recordID.recordName] = share.url }
        }
        let id = (r["sourceID"] as? String) ?? r.recordID.recordName
        let vis = MomentVisibility(rawValue: r["visibility"] as? String ?? "") ?? .friends
        let creator = r["creatorID"] as? String ?? ""
        let locked = vis == .subscribers && r.recordID.zoneID.ownerName != CKCurrentUserDefaultName && r.recordID.recordName.hasPrefix("public_") && !subscribedCreators.contains(creator)
        var out = SocialMoment(id: id, creatorID: r["creatorID"] as? String ?? "", creatorName: r["creatorName"] as? String ?? "", title: r["title"] as? String ?? "Moment", description: r["description"] as? String ?? "", coverRef: cover, createdAt: r.creationDate ?? .now, startAt: r["startAt"] as? Date, endAt: r["endAt"] as? Date, locationName: r["locationName"] as? String, coarsePlace: r["coarsePlace"] as? String, visibility: MomentVisibility(rawValue: r["visibility"] as? String ?? "") ?? .friends, memberIDs: r["memberIDs"] as? [String] ?? [], memberNames: r["memberNames"] as? [String] ?? [], contributionCount: r["contributionCount"] as? Int ?? 0, mediaCount: r["mediaCount"] as? Int ?? 0, commentCount: r["commentCount"] as? Int ?? 0, reactionCounts: [:], shareCount: r["shareCount"] as? Int ?? 0, isLive: (r["isLive"] as? Int ?? 0) == 1, templateID: r["templateID"] as? String, remixedFromID: r["remixedFromID"] as? String, shareURL: shareURL, allowsReshare: (r["allowsReshare"] as? Int ?? 1) == 1, allowsDownload: (r["allowsDownload"] as? Int ?? 1) == 1, allowsContributions: (r["allowsContributions"] as? Int ?? 1) == 1, isTeaser: (r["isTeaser"] as? Int ?? 0) == 1, place: Self.place(from: r), signature: r["signature"] as? String, creatorPublicKey: r["creatorPublicKey"] as? String, signedAt: r["signedAt"] as? Date)
        out.isLocked = locked
        return out
    }

    static func contribution(from r: CKRecord, media: MediaStore) async throws -> Contribution {
        let kind = Contribution.Kind(rawValue: r["kind"] as? String ?? "photo") ?? .photo
        var ref: MediaRef? = nil
        if let asset = r["media"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            let ext = kind == .video ? "mp4" : kind == .voice ? "m4a" : "jpg"
            if let local = try? await media.store(data, extension: ext) { ref = MediaRef(kind: kind == .video ? .video : kind == .voice ? .voice : .photo, localRef: local, remoteID: r.recordID.recordName) }
        }
        let momentName = (r["momentRef"] as? CKRecord.Reference)?.recordID.recordName ?? ""
        return Contribution(id: r.recordID.recordName.replacingOccurrences(of: "contrib_", with: ""), momentID: momentName, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", kind: kind, media: ref, caption: r["caption"] as? String ?? "", createdAt: r.creationDate ?? .now, originalTimestamp: r["originalTimestamp"] as? Date, reactionCounts: [:], commentCount: 0, uploadState: .uploaded)
    }
}
