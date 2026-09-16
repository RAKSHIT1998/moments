# MOMENT

**Be there. Remember it.**

A Moment is an experience shared by the people who were there. You make it, they add their side — one place, everyone's photos, nothing lost in a group chat. NOW is what's happening right now (gone in 24 hours unless you keep it). Underneath sits the original private, on-device memory layer (screenshots → people, plans, promises), reachable from your profile and never synced.

## Social layer (backend: CloudKit)

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

Simulator and tests use `InMemoryBackend`; on a device signed into iCloud the app uses `CloudKitBackend` with container `iCloud.com.rakshitbargotra.moment`. Nothing social is faked with local-only data in Release: if iCloud is unavailable the UI says so and keeps private Moments working.

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
