# MOMENT

**Be there. Remember it.**

A Moment is an experience shared by the people who were there. You make it, they add their side — one place, everyone's photos, nothing lost in a group chat. NOW is what's happening right now (gone in 24 hours unless you keep it). Underneath sits the original private, on-device memory layer (screenshots → people, plans, promises), reachable from your profile and never synced.

## Social layer (backend: decentralised mesh + relays; iCloud optional)

```
Moment/Social/
  SocialModels.swift      value types that cross the backend boundary (SocialMoment, Contribution, NowPost, …)
  SocialBackend.swift     protocol + FeedRanker, RelationshipGraph, MomentTimeline, ContentModeration
  CloudKitBackend.swift   production: private DB custom zone for Moments, CKShare for group Moments/invites
                          (system UICloudSharingController → real share links), shared DB for others' Moments,
                          public DB for profiles / follows / public Moments / NOW / reports, CKAssets for media,
                          CKDatabaseSubscription → silent push → local "N new additions" notification
  InMemoryBackend.swift   DEBUG: same contract, in-process, seeded fictional people (-uitest / -demo / unit tests)
  SocialService.swift     what the UI talks to: session, ranked feed, caches, invites, engagement, NOW, safety, inbox
  UploadQueue.swift       offline-first, disk-persisted queue with backoff; contributions show as "uploading"
  MediaPipeline.swift     ≤2048px JPEG with EXIF stripped (capture date kept separately), 1080p H.264 transcode
Moment/Features/Social/   Home (NOW strip + feed), Moment page (timeline of sides, ADD YOUR SIDE, comments,
                          reactions, invite), New Moment, Add Side, NOW composer/viewer, Discover, Inbox
                          (activity / invites / DMs), Profile + friendship pages, safety (block/mute/report/private),
                          onboarding, "Add to a Moment" from the share sheet
```

What's built on top of that contract (all real data, nothing generated):
- **Moment Together / live rooms** — start a live Moment, friends see it under *Happening now* and tap **JOIN**; members get a camera shortcut to add as it happens.
- **I WAS THERE / ADD YOUR SIDE** — explicit participation only; every contribution stays owned by its author (remove any time).
- **Perspectives** — Everyone / one person, same night from each side. **Timeline** by real capture time. **THE MOMENT** highlights (most reacted, busiest hour, who added most) and **Replay** (cinematic auto-advancing timeline with joins).
- **NOW + Anyone up?** — status presets (drinks, food, drive…), JOIN, and *Make it a Moment* which creates a live Moment with everyone who joined.
- **Groups** (own Moments, NOW, chat), **Collections**, **Time Machine** (1/2/3… years ago today), **Moment Map** (city-level pins, geocoded on device), **Passport**, **Year in Moments**, **You + X / Our story** chains.
- **Moment QR** (scan to join with the system scanner), **Moment Card** image share, **Mystery Moments** (blurred until Reveal), **Merge** suggestions for same-day overlapping Moments, pinned Moments, @mentions.

**Fully decentralised — no MOMENT servers, no sign-up, no data collection.** The default network is a phone-to-phone mesh plus open relays (`Moment/Social/Decentralized/`). A person *is* their Curve25519 key; there is no account. Every action — profile, Moment, side, comment, reaction, NOW, follow, join, claim — is a small **signed event** (`SignedEvent`: SHA‑256 id, Ed25519 signature) that anyone can verify and nobody can forge or alter. Events sync directly between nearby phones over Wi‑Fi/Bluetooth (`MeshTransport`, MultipeerConnectivity, HAVE/WANT/EVENTS) and, for people elsewhere, through **relays** — dumb WebSocket servers anyone can run (`relay/server.js`, ~120 lines). Non‑public Moments are AES‑GCM encrypted under a per‑Moment key that only travels inside the invite link/QR (`moment://join/<id>#<key>`), so relays and strangers store bytes they can't read; only public Moments expose a venue and a 0.1° geo cell for "what's happening near me". Deletes are signed events by the same author. Blocks, mutes and collections stay on the phone. Every phone keeps its own append‑only copy (`EventStore`, `events.jsonl`) and derives all state from it — the app works with zero relays, offline, in a room. iCloud (CloudKit private DB + `CKShare`) remains available as an opt‑in alternative under Settings → Network. `.moment` packages still let two phones exchange a Moment via AirDrop.

**Identity without accounts.** On first launch `IdentityService` creates a Curve25519 signing key in the Keychain; its fingerprint is the person's **MOMENT ID** (`MMT-7K3F-9Q2X-4LMB`). The public key is published on the profile, every Moment is signed at creation (id · creator · title · time) and the app shows *Signed ✓* only when the creator's key verifies it. The "password" is a generated 12-word recovery phrase that encrypts a backup of the key — no server, no reset flow, no leak surface. `web/` holds the static site (landing, privacy, support, `/m/<id>` and `/u/<id>` link fallbacks, AASA template) and the venue **owner dashboard** (CloudKit JS, public DB only).

**Search is a globe.** The Search tab is a MapKit globe (`ExploreMapView`): zoomed out, clusters show where public Moments are happening in the world; zoom in and venues appear; tap a place for its page. The camera position is the only "location" queried, unless the user taps *Near me*.

**Location layer.** Venues (`SocialPlace`: name, area, coordinates from Apple Maps POI search) attach to Moments, events and NOW posts. *Nearby* asks the device for one when-in-use fix and queries "within 3 km" (CloudKit `distanceToLocation` on a `CLLocation` field; haversine in-memory) — the user's coordinate is never stored or uploaded. Place pages aggregate everything at a venue (photos, live events, who's here now, regulars), let anyone add photos / start an event / say they're here, and can be **claimed** by the business (pending manual verification; owner gets a pinned note and plain-count insights). Friends' NOW posts with a venue near you raise a local notification.

Simulator and tests use `InMemoryBackend`; on a device signed into iCloud the app uses `CloudKitBackend` with container `iCloud.com.rakshitbargotra.moment`. Nothing social is faked with local-only data in Release: if iCloud is unavailable the UI says so and keeps private Moments working.

## Messaging & the mechanics

**Chats** is a tab. Threads: day separators, quote replies, long‑press emoji reactions, photos, **voice notes** (hold the mic; AAC in a sealed message), Moment cards, **group chats** (one per group), **read receipts** ("Seen" / "Seen by …") and **typing indicators**. Unread state never leaves the phone. Over the mesh a read receipt is a small signed `seen` event; typing is an `EPHEMERAL` frame that peers and relays forward and never store (`relay/server.js`). CloudKit has no live channel, so typing is simply absent there.

**Replay → video**: the share button in Replay renders the Moment as a 1080×1920 H.264 clip — title card, every side in order with who/when, an end card with the invite link — capped at 60 s by shortening beats before dropping any (`ReplayExporter`). Nothing is generated or invented; it's the sides, in order.

**Only a Moment made by everyone can do these** (`MomentMechanics.swift`): *Same second* pairs two people's photos taken within 20 s; *Fill the gap* finds ≥45‑minute holes in the timeline and lets a member add to them or ask a witness (the question lands in their chat with the Moment attached); *Rituals* link weekly Moments with the same title into a series with a streak and next date.

## Meet (dating through real overlap)

Not a stack of strangers. Opt in (18+) and you only appear to people you've **actually crossed paths with**: same Moment, same venue this month, same ritual, or out right now nearby (`MeetRanker.overlaps`). Every card leads with the overlap ("Both at Bastian this month"), then Hinge‑style prompts; photos are the person's own sides from their Moments — nothing uploaded just for this. Like with a comment on a prompt or photo; mutual likes become a match (deterministic id on both phones) and open a chat whose first line is the reason you're talking. Preferences apply both ways; *hide from people I know* keeps you out of the stacks of anyone you follow or who follows you; *overlap only* is the default and either side can insist on it. Leaving removes your profile everywhere. On the mesh a `dating` event carries the opted‑in profile and each `like` is sealed to the one person it's for (`SealedForPeer`), so relays and bystanders never learn who likes whom — tested in `DecentralizedMeetTests`.

## Creator economy (subscriptions)

Creators sell access to **subscribers-only Moments** from their profile (Profile → *Earn from your Moments*, or Settings → Creators). One plan per creator: a name, a pitch, up to three perks, and a price tier. Fans pay through the App Store — **non‑renewing 30‑day products** `creator.30d.t1/t2/t3` (≈ ₹199 / ₹499 / ₹999; Apple localises the price) — so there is no card handling in the app and nothing auto‑renews. `SocialService.subscribe(to:)` runs the StoreKit 2 purchase, then records the subscription (`SocialBackend.subscribe`). Locked Moments show a frosted preview (cover + title) with an *Unlock* button; sides never reach a non‑subscriber.

**How access is enforced**
- *Decentralised (default)*: a paid Moment's full payload is AES‑GCM sealed under the creator's content key; the event carries only a readable preview. When a `subscribe` event reaches the creator's phone, it emits a `grant` event with that key sealed to the subscriber's X25519 agreement key (published in their profile). Relays and everyone else store the grant but can't open it. Tested end to end in `DecentralizedCreatorTests`.
- *iCloud*: the preview is a `PublicMoment` record with `visibility = subscribers`; the sides live in the creator's private zone, and the creator's phone adds active subscribers to the Moment's `CKShare` when it refreshes.

**Money**: Apple pays MOMENT's developer account (after its ~30% cut); MOMENT pays creators `CreatorEconomics.creatorShare` (80%) of the net once a month to the payout handle they entered (UPI / PayPal / IBAN, stored in the plan record and read only by the payout process). The app's *Earn* screen shows an estimate computed from active subscriptions with exactly that formula. There is no wallet, no token, and no fee hidden in the app; fraud checks on transaction ids happen at payout time, not on‑device.

## Requirements

- Xcode 16.2 (iOS 18.2 SDK), Swift 6 toolchain, Swift 5 language mode
- Deployment target **iOS 18.0** — every device that runs iOS 17 runs iOS 18; SwiftData on 17 has known relationship bugs
- `xcodegen` (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`

```sh
xcodegen generate
open Moment.xcodeproj                      # or:
Tools/run_sim.sh -demo -uitest             # build + install + launch on iPhone 16 Pro simulator with demo data
xcodebuild -project Moment.xcodeproj -scheme Moment -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

**Running on a device (one-time):** open the project in Xcode, select the `Moment`, `MomentShareExtension` and `MomentWidget` targets → Signing & Capabilities, and confirm the *App Groups* capability with `group.com.rakshitbargotra.moment` (Xcode registers the group on your developer account; `xcodebuild -allowProvisioningUpdates` cannot create App Groups). After that, `xcodebuild -sdk iphoneos build -allowProvisioningUpdates` works from the command line.

Launch arguments (DEBUG only): `-demo` seeds clearly-labelled demo data through the real pipeline and the in-memory social backend, `-uitest` skips onboarding and uses the in-memory social backend, `-reset` wipes the store first, `-reset-onboarding` shows onboarding again.

## Architecture

```
Moment/
  App/          MomentApp, AppEnvironment (DI), RootView, Navigation, AppIntents, DemoData (DEBUG)
  Core/         DesignSystem (semantic colors, type, components), Extensions, Security (Keychain, AES-GCM, Face ID), Logging
  Models/       SwiftData: Memory, Person, Plan, Promise, GiftIdea, Event, Place, Source, MemoryRelation, Insight, UserProfile, EntityCorrection
  AI/           IntelligenceProvider (protocol) + Local / Remote / Mock providers
                TextNormalizer → EntityRecognizer → IntentClassifier → MemoryExtractor → ImportanceEngine
                TemporalParser, SearchEngine (retrieval-first), SurfaceEngine, InsightEngine, ContextResolver
  Services/     StorageService, MediaStore (encrypted), ImportService (pipeline), OCRService, SpeechService,
                NotificationService (+ budget), SurfaceService, SearchService, MemoryActions, ExportService,
                DataLifecycleService, SubscriptionService (StoreKit 2), ShareInboxService, Calendar/Contacts (optional)
  Features/     Onboarding, Home, Capture, Memory, People, Plans, Search, Vault (archive, review, stats), Insights, Settings, Paywall
Shared/         App-group contracts used by the app, Share Extension and Widget
Extensions/     ShareExtension — drops raw items into the app-group inbox; the app understands them
Widgets/        MomentWidget — reads a small snapshot the app writes; no SwiftData in the widget process
Tests/          Unit (engines, extraction, persistence, export, delete) and UI
```

### The pipeline

`CaptureInput → normalize (OCR / speech / PDF / page title) → analyze (provider) → validate → persist (resolve people & places, create plans/promises/gifts/events, link related memories, score importance, schedule surfacing)`.

Everything captured lands in **Review** (Home strip / Vault) as *needs review*; the capture result screen lets the user save, correct the person, edit, or discard. Home ranks a feed daily (`SurfaceEngine`): one hero moment, editorial cards with a single primary action, "useful / not useful" feedback that tunes category weights, and "on this day" only for notable memories.

### Intelligence

- **Local (default):** `NaturalLanguage` (NLTagger, NLTokenizer, NLEmbedding) plus a deterministic, explainable extraction engine. Every extracted item carries the quote it came from, a confidence, and only facts the text supports. Ambiguity lowers confidence — it is never resolved by guessing.
- **Remote (opt-in, off by default):** Claude Messages API (`claude-opus-5`) over raw HTTPS with structured JSON output, using the user's own key stored in the Keychain. Only the current capture is sent, never the memory database. Output is validated (`AnalysisValidator`) before it becomes state, and user content is wrapped in a data envelope (`PromptInjectionGuard`).
- **Mock:** used by tests.

`FoundationModels` is not in the iOS 18.2 SDK; when the project moves to Xcode 26 it can become another `IntelligenceProvider` without touching the UI.

### Privacy & security

- Store: SwiftData in the app container with Data Protection (complete until first unlock).
- Media: AES-GCM (CryptoKit) with a per-device Keychain key; "Delete All Data" destroys the key.
- Optional Face ID lock, optional Calendar (context only, never written without confirmation), optional per-person Contacts link (never bulk import).
- Analytics: opt-in, event names only, counted locally in V1.
- Privacy Center in Settings shows what is stored / processed / sent / shared.

### Moments (the shareable layer)

A **Moment** (`MomentStory`) is a beautiful object composed from memories — a trip, a month, a year, a friendship — by `StoryComposer` from stored data only (photos, quotes people actually said, people, places, plans and their real status). Templates (`MomentTemplate`, built in) decide the slides and the look; `StorySlideView` renders them; `StoryExporter` produces 1080-px images and an H.264 video (no music — nothing licensed ships) in 9:16 / 1:1 / 4:5 / 16:9.

Sharing is **local-first and server-less**: a Moment leaves the phone only as a rendered image/video through the share sheet, or as a self-contained `.moment` file (`MomentPackage`, UTI `com.rakshitbargotra.moment.package`) sent via iMessage/WhatsApp/AirDrop. Opening a `.moment` in MOMENT shows the immersive viewer with reactions native to memories, **"You were there too — add your side"** (send it back), and **"Make your own"** (the same template over the recipient's memories, credited). Memory Drop turns a pick of photos into a Moment through the real capture pipeline; month/year recaps, "Tell me about my Goa trip", friendship pages ("You + Rahul"), core-memory hints and contextual invitations ("Rahul was there too. Send it to him?") complete the loop. `FeatureFlags` gates the growth experiments; growth events are counted locally.

Not built, on purpose: public discovery/feeds, follower profiles, a template marketplace, report/block, universal-link web previews. Each needs a backend and a domain; nothing in the UI pretends otherwise.

### Surfacing

`SurfaceEngine` scores each memory for *right now*: pending promises, birthdays with saved gift ideas, tasks due, plan windows approaching, pinned/important items. Home shows at most six; notifications are capped by a daily budget (default 2) and never say "come back".

## Subscriptions

StoreKit 2 products `moment_pro_monthly`, `moment_pro_yearly`, `moment_pro_lifetime` (local config in `Moment/Resources/Moment.storekit`). Free tier: 100 memories. Viewing, exporting and deleting are never gated.

## App Store copy

Subtitle: *Never forget what matters.*

> MOMENT is your private AI memory for the things you don't want to forget. Throw in a screenshot, voice note, photo, link or thought. MOMENT understands the context, remembers what matters, and brings it back when it's useful. Plans. People. Promises. Ideas. Memories. Forget it. MOMENT will remember.
