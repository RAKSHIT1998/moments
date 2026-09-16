import Foundation
import CloudKit
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
        if let cover = draft.coverData, let url = try? Self.tempFile(cover, ext: "jpg") { record["cover"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: privateDB)
        let moment = try await moment(from: saved)
        if draft.visibility == .publicAll { try await mirrorPublic(moment, record: saved) }
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
        let saved = try await save(record, in: db)
        let updated = try await self.moment(from: saved)
        if moment.visibility == .publicAll { try await mirrorPublic(updated, record: saved) } else { _ = try? await publicDB.deleteRecord(withID: CKRecord.ID(recordName: "public_\(moment.id)")) }
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

    private func mirrorPublic(_ moment: SocialMoment, record: CKRecord) async throws {
        let id = CKRecord.ID(recordName: "public_\(moment.id)")
        let pub = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "PublicMoment", recordID: id)
        for key in ["creatorID", "creatorName", "title", "description", "startAt", "endAt", "locationName", "coarsePlace", "memberIDs", "memberNames", "contributionCount", "mediaCount", "commentCount", "shareCount", "isLive", "templateID", "remixedFromID"] { pub[key] = record[key] }
        pub["visibility"] = MomentVisibility.publicAll.rawValue
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
        if let mediaData, let url = try? Self.tempFile(mediaData, ext: "jpg") { record["media"] = CKAsset(fileURL: url) }
        let saved = try await save(record, in: publicDB)
        var out = post; out.id = saved.recordID.recordName
        return out
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
            out.append(NowPost(id: r.recordID.recordName, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: ref, createdAt: r.creationDate ?? .now, expiresAt: r["expiresAt"] as? Date ?? .now, coarsePlace: r["coarsePlace"] as? String, savedToMomentID: nil))
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
                    out.append(Conversation(id: r.recordID.recordName, participantIDs: r["participantIDs"] as? [String] ?? [], participantNames: r["participantNames"] as? [String] ?? [], lastMessage: r["lastMessage"] as? String ?? "", updatedAt: r.modificationDate ?? .now))
                }
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func messages(conversationID: String) async throws -> [DirectMessage] {
        let (record, db) = try await anyRecord(name: conversationID, type: "Conversation")
        let q = CKQuery(recordType: "Message", predicate: NSPredicate(format: "conversationRef == %@", CKRecord.Reference(recordID: record.recordID, action: .deleteSelf)))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return try await query(q, in: db, zone: record.recordID.zoneID, limit: 500).map { r in
            DirectMessage(id: r.recordID.recordName, conversationID: conversationID, authorID: r["authorID"] as? String ?? "", authorName: r["authorName"] as? String ?? "", text: r["text"] as? String ?? "", media: nil, momentID: r["momentID"] as? String, createdAt: r.creationDate ?? .now)
        }
    }

    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage {
        guard ContentModeration.check(message.text) == .ok else { throw SocialError.notAllowed }
        let (conv, db) = try await anyRecord(name: message.conversationID, type: "Conversation")
        let r = CKRecord(recordType: "Message", recordID: CKRecord.ID(recordName: "msg_\(message.id)", zoneID: conv.recordID.zoneID))
        r["conversationRef"] = CKRecord.Reference(recordID: conv.recordID, action: .deleteSelf)
        r.parent = CKRecord.Reference(recordID: conv.recordID, action: .none)
        r["authorID"] = message.authorID; r["authorName"] = message.authorName; r["text"] = message.text; r["momentID"] = message.momentID
        if let mediaData, let url = try? Self.tempFile(mediaData, ext: "jpg") { r["media"] = CKAsset(fileURL: url) }
        let saved = try await save(r, in: db)
        conv["lastMessage"] = message.text
        _ = try? await save(conv, in: db)
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
        return SocialUser(id: r["userID"] as? String ?? r.recordID.recordName.replacingOccurrences(of: "profile_", with: ""), displayName: r["displayName"] as? String ?? "Someone", handle: r["handle"] as? String ?? "", bio: r["bio"] as? String ?? "", avatarRef: avatar, isPrivateAccount: (r["privateAccount"] as? Int ?? 0) == 1, momentCount: r["momentCount"] as? Int ?? 0, sharedCount: r["sharedCount"] as? Int ?? 0, placeCount: r["placeCount"] as? Int ?? 0, peopleCount: r["peopleCount"] as? Int ?? 0, createdAt: r.creationDate ?? .now)
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
        return SocialMoment(id: id, creatorID: r["creatorID"] as? String ?? "", creatorName: r["creatorName"] as? String ?? "", title: r["title"] as? String ?? "Moment", description: r["description"] as? String ?? "", coverRef: cover, createdAt: r.creationDate ?? .now, startAt: r["startAt"] as? Date, endAt: r["endAt"] as? Date, locationName: r["locationName"] as? String, coarsePlace: r["coarsePlace"] as? String, visibility: MomentVisibility(rawValue: r["visibility"] as? String ?? "") ?? .friends, memberIDs: r["memberIDs"] as? [String] ?? [], memberNames: r["memberNames"] as? [String] ?? [], contributionCount: r["contributionCount"] as? Int ?? 0, mediaCount: r["mediaCount"] as? Int ?? 0, commentCount: r["commentCount"] as? Int ?? 0, reactionCounts: [:], shareCount: r["shareCount"] as? Int ?? 0, isLive: (r["isLive"] as? Int ?? 0) == 1, templateID: r["templateID"] as? String, remixedFromID: r["remixedFromID"] as? String, shareURL: shareURL, allowsReshare: (r["allowsReshare"] as? Int ?? 1) == 1, allowsDownload: (r["allowsDownload"] as? Int ?? 1) == 1, allowsContributions: (r["allowsContributions"] as? Int ?? 1) == 1)
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
