# MOMENT

**Your work. Your price. Your keys.**

MOMENT is a decentralised creator platform: creators post photo sets and video clips, set one subscription price of their own, sell individual sets, and charge for anything a fan asks for — a custom photo, a call, a meeting. The platform fee is **10%** on card checkout, and there is no company server holding the content. Underneath sits the original private, on-device memory layer (screenshots → people, plans, promises), reachable from your profile and never synced.

## Social layer (backend: decentralised mesh + relays; iCloud optional)

```
Moment/Social/
  SocialModels.swift      value types that cross the backend boundary (VaultSet, CreatorPlan, Booking, …)
  SocialBackend.swift     protocol + RelationshipGraph, ContentModeration
  CreatorFeed.swift       CreatorFeedBuilder — turns sets + plans + purchases into gated posts
  Reels.swift             ReelBuilder — the video-post feed, locked clips included
  CloudKitBackend.swift   production: private DB custom zone, CKShare for buyers/subscribers,
                          public DB for profiles / follows / storefront windows / reports, CKAssets for media,
                          CKDatabaseSubscription → silent push → local notification
  InMemoryBackend.swift   DEBUG: same contract, in-process, seeded fictional creators (-uitest / -demo / unit tests)
  SocialService.swift     what the UI talks to: session, feed, storefront, subscriptions, asks, chats, safety
  UploadQueue.swift       offline-first, disk-persisted queue with backoff
  MediaPipeline.swift     ≤2048px JPEG with EXIF stripped, 1080p H.264 transcode
  SecureMedia.swift       ScreenGuard / SecureLayer / Watermark — paid media is capture-resistant on iOS
  CallScheduling.swift    CreatorAvailability + CallSlots (bookable times) + CallClock (the paid clock)
  CallSignaling.swift     CallSignal / CallSignalChannel / IceConfig — the sealed handshake, no media
  CallEngine.swift        one WebRTC call: peer-to-peer audio+video, the countdown, mute/camera/speaker
Moment/Features/Social/   Home (creator feed), Reels, set pages and checkout, Studio (creator mode),
                          Profile (Posts · About), Chats (incl. locked messages, voice notes), Notifications,
                          safety (block/mute/report/private), onboarding
```

**Fully decentralised — no MOMENT servers, no sign-up, no data collection.** The default network is a phone-to-phone mesh plus open relays (`Moment/Social/Decentralized/`). A person *is* their Curve25519 key; there is no account. Every action — profile, post, purchase, subscription, follow, comment — is a small **signed event** (`SignedEvent`: SHA‑256 id, Ed25519 signature) that anyone can verify and nobody can forge or alter. Events sync directly between nearby phones over Wi‑Fi/Bluetooth (`MeshTransport`, MultipeerConnectivity, HAVE/WANT/EVENTS) and, for people elsewhere, through **relays** — dumb WebSocket servers anyone can run (`relay/server.js`, ~120 lines). Paid content is AES‑GCM encrypted under a per‑set key that only the creator's phone hands out, sealed to one buyer at a time, so relays and strangers store bytes they can't read. Deletes are signed events by the same author. Blocks and mutes stay on the phone. Every phone keeps its own append‑only copy (`EventStore`, `events.jsonl`) and derives all state from it — the app works with zero relays, offline, in a room. iCloud (CloudKit private DB + `CKShare`) remains available as an opt‑in alternative under Settings → Network.

**Identity without accounts.** On first launch `IdentityService` creates a Curve25519 signing key in the Keychain; its fingerprint is the person's **MOMENT ID** (`MMT-7K3F-9Q2X-4LMB`). The public key is published on the profile and the app shows *Signed ✓* only when the author's key verifies the event. The "password" is a generated 12-word recovery phrase that encrypts a backup of the key — no server, no reset flow, no leak surface. `web/` holds the static site (landing, privacy, support, link fallbacks, AASA template).

Simulator and tests use `InMemoryBackend`; on a device signed into iCloud the app can use `CloudKitBackend` with container `iCloud.com.rakshitbargotra.moment`. Nothing social is faked with local-only data in Release: if the network is unavailable the UI says so.

## The app

Tabs are **Home · Create · Chats · Profile**. Home is the **creator feed**: a column of posts from people you follow or pay, where a locked one shows its cover blurred with *Unlock for ₹X* or *Subscribe · ₹X* on it — nothing is teased without naming the price. `CreatorFeedBuilder` decides each post's gate (`open` / `buy` / `subscribe`) and never shows a lock it can't explain. **Reels** (from the Home header) is the video-post feed: free and bought clips play, paid ones are a locked card whose clip was never sent to the device. **Create** offers a photo set, a video post, a message to every subscriber, and your subscription. **Profile** is a creator page — a banner, the numbers that matter, then **Posts** and **About**; your own page leads with *Start earning* / *Creator mode*.

## Messaging

**Chats** is a tab. Threads: day separators, quote replies, long-press emoji reactions, photos, **voice notes** (hold the mic; AAC in a sealed message), **locked messages** (a priced photo — a hidden one-item set, so the media never travels unpaid), **group chats**, **read receipts** and **typing indicators**. Unread state never leaves the phone. Over the mesh a read receipt is a small signed `seen` event; typing is an `EPHEMERAL` frame that peers and relays forward and never store (`relay/server.js`). CloudKit has no live channel, so typing is simply absent there.

## Selling: subscription, sets, bundles, asks, tips

Creators have **one subscription at a price they choose**, which opens every post they mark *Subscribers* (`VaultSet.subscribersOnly`). They also sell **sets** (photos or clips, free or priced) one at a time, and answer **asks** — a fan requests a photo, a call, a meeting or anything else, and the creator names a price for that one thing (`asked → quoted → requested → accepted`; money counts only from `accepted`). Also: **bundles** (3/6/12 months at the creator's discount), **mass messages** to every active subscriber in their own chat, and **tip goals** whose progress is the real total tipped. Studio shows where the month's money came from and the top supporters.

Paid media is capture-resistant on iOS (screenshots and recordings come out blank) and watermarked with the viewer's MOMENT ID; the creator is told when someone captures. Nothing stops a second camera — the app says so instead of pretending.

Studio shows this month's earnings **with the rail named**, because the take rate differs: on card checkout MOMENT keeps 10%; through Apple IAP, Apple takes 30% first and the creator keeps 80% of the rest (`CreatorEconomics`). A set's window (title, price, cover) is public; its contents are sealed under a per-set key that the creator's phone hands to buyers only — a third device with every byte can open nothing (`DecentralizedStorefrontTests`). A subscription hands the same key to every active subscriber and stops when they lapse. Withdrawing rotates the key.

**Calls.** A creator sets weekly hours in their own time zone (`CreatorAvailability`) and prices a video or voice call by the minute; a buyer picks from the slots that produces and nothing else. The call happens in the app over **WebRTC, peer to peer** — the media never touches a server, and the only thing crossing the relay is a handshake sealed to the other person, because ICE candidates carry IP addresses. The paid clock starts when the two phones actually connect, not when the slot was booked, so neither side loses minutes to the other being late; the last minute is warned, 30 seconds of grace follow, then it hangs up. Time bought mid-call is charged at the booking's own rate. A video call is paid content: blank in screenshots, watermarked with the viewer's ID, and the creator is told if it's captured. Nothing is recorded and there is no server that could record it. MOMENT runs no TURN server, so on the few networks that block direct connections the call fails and says why; a creator can add their own under Settings → Network.

**No payment processor is wired yet.** `buySet(reference:)` records a reference; nothing calls a processor and no payouts run. Full economics, the adult-content constraints and everything still missing before money moves: `CREATOR-PLATFORM.md`. Go-live runbook: `LAUNCH.md`.

## Web client & Android

`web/app` is **MOMENT Web**: a PWA that speaks the same protocol — Ed25519 identity in the browser (tweetnacl), signed events with the app's canonical form, AES-GCM opening of sealed content, relay subscriptions. Install to home screen on Android; wrap as a TWA for Play. Interop is tested in the scratch harness (relay verifies web-signed events; CryptoKit boxes open in the web code). See `LAUNCH.md` for the Android path.

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

### Story cards (the private layer's shareable output)

This belongs to the private memory layer, not the creator platform. A **story card** (`MomentStory`) is a beautiful object composed from memories — a trip, a month, a year, a friendship — by `StoryComposer` from stored data only (photos, quotes people actually said, people, places, plans and their real status). This layer never syncs. Templates (`MomentTemplate`, built in) decide the slides and the look; `StorySlideView` renders them; `StoryExporter` produces 1080-px images and an H.264 video (no music — nothing licensed ships) in 9:16 / 1:1 / 4:5 / 16:9.

Sharing is **local-first and server-less**: a card leaves the phone only as a rendered image/video through the share sheet, or as a self-contained `.moment` file (`MomentPackage`, UTI `com.rakshitbargotra.moment.package`) sent via iMessage/WhatsApp/AirDrop. Opening one in MOMENT shows the immersive viewer and **"Make your own"** (the same template over the recipient's memories, credited). Memory Drop turns a pick of photos into a card through the real capture pipeline; month/year recaps and "Tell me about my Goa trip" complete the loop. `FeatureFlags` gates the growth experiments; growth events are counted locally.

### Surfacing

`SurfaceEngine` scores each memory for *right now*: pending promises, birthdays with saved gift ideas, tasks due, plan windows approaching, pinned/important items. Home shows at most six; notifications are capped by a daily budget (default 2) and never say "come back".

## MOMENT Pro (the private layer's own subscription)

Separate from creator subscriptions. StoreKit 2 products `moment_pro_monthly`, `moment_pro_yearly`, `moment_pro_lifetime` (local config in `Moment/Resources/Moment.storekit`). Free tier: 100 memories. Viewing, exporting and deleting are never gated.

## App Store copy

Subtitle: *Your work. Your price.*

> MOMENT is where creators get paid for their own work. Post photo sets and clips — some free, some locked. Set one subscription price: yours, not ours. Sell a single set, or name your price when someone asks for something specific — a photo, a call, your time. You keep 90%.
>
> Nothing you post sits on a company server. Your posts stay on your own storage and buyers get a key, not a copy from us — so no algorithm decides who sees you, and nobody can take your page down. Paid photos are blank in screenshots and carry the viewer's ID.

Note: the listing above describes the platform as built. Adult content is **not** permitted under this listing — see `CREATOR-PLATFORM.md` for what that path would require instead.
