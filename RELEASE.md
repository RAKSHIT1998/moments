# MOMENT — App Store release package (1.0, build 1)

Everything below is derived from the actual project. Nothing is invented: where a value must come from you (URLs, App Store Connect record), it is listed under **Blockers**.

## Identity

| | |
|---|---|
| App name | MOMENT |
| Bundle ID (app) | `com.rakshitbargotra.moment` |
| Bundle ID (Share Extension) | `com.rakshitbargotra.moment.share` |
| Bundle ID (Widget) | `com.rakshitbargotra.moment.widget` |
| App Group | `group.com.rakshitbargotra.moment` |
| Team | `48TGY734WW` (automatic signing) |
| Marketing version | 1.0 |
| Build | 1 (no build has been uploaded yet; increment `CURRENT_PROJECT_VERSION` in `project.yml` for every upload) |
| Deployment target | iOS 18.0, iPhone only, portrait only |
| Dependencies | None. Apple frameworks only (SwiftUI, SwiftData, Vision, VisionKit, NaturalLanguage, Speech, PDFKit, StoreKit 2, CryptoKit, LocalAuthentication, EventKit, Contacts, WidgetKit, AppIntents, BackgroundTasks). |

## Capabilities & entitlements (only what is used)

- App Groups (`group.com.rakshitbargotra.moment`) — Share Extension → app inbox, widget snapshot. App, Share, Widget targets.
- Keychain access group (`$(AppIdentifierPrefix)com.rakshitbargotra.moment`) — media encryption key, optional cloud-AI key. App target.
- Background Modes: `fetch` (BGAppRefreshTask `com.rakshitbargotra.moment.refresh`, ~every 6h+, re-runs surfacing so a "birthday in 7 days" notification is scheduled even if the app hasn't been opened) and `remote-notification` (silent CloudKit pushes when a shared Moment changes).
- iCloud → CloudKit, container `iCloud.com.rakshitbargotra.moment` — shared Moments, profiles, NOW, reports. App target only. SwiftData mirroring is explicitly off (`cloudKitDatabase: .none`); private memory never syncs.
- Push Notifications (`aps-environment`) — only for CloudKit database subscriptions (content-available); the app never sends its own pushes. Xcode/`-allowProvisioningUpdates` must enable **iCloud (CloudKit)** and **Push Notifications** on the App ID; the CloudKit container is created on first signed build.
- Not enabled (not needed): Sign in with Apple, Associated Domains, HealthKit, Location.

## Permissions (all contextual, none at onboarding)

| Permission | When asked | Info.plist string |
|---|---|---|
| Camera | Tapping **Scan** | Use your camera to scan documents and screens into Moments. Scans are processed on this iPhone. |
| Microphone | Tapping **Voice** | Use your microphone to turn voice notes into Moments. |
| Speech Recognition | Tapping **Voice** | Use speech recognition to understand your voice Moments. On-device recognition is used when your iPhone supports it. |
| Photos | Never (PhotosPicker, no library access) | — |
| Notifications | Home card "At the right time" → *Notify me*, or setting a reminder | System prompt |
| Face ID | Turning on *Require Face ID* in Settings | Lock your Moments so only you can open them. |
| Calendar | Settings → Connect Calendar (optional, read-only context; events only added after an explicit confirmation dialog) | Optional. Use your calendar as context… never adds or changes events without asking you first. |
| Contacts | Person profile → *Link to a contact* (system picker, one contact) | Optional. Link a person in MOMENT to one of your contacts. MOMENT never imports your address book. |

## Privacy manifest (`PrivacyInfo.xcprivacy`, all three targets)

- Tracking: **No**. Tracking domains: none.
- Collected data types: **none** (see App Privacy label below).
- Required-reason APIs: app target declares `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` (app's own settings). Extensions declare none (they don't use UserDefaults, file timestamps, disk space, boot time or keyboard APIs).

## App Privacy label (App Store Connect → App Privacy)

Answer: **Data Not Collected.**

| Data type | Collected by developer? | Linked | Tracking | Notes |
|---|---|---|---|---|
| Contact info, contacts, photos/videos, audio, messages, user content, identifiers, usage data, diagnostics, location, purchases, financial, health, browsing/search history | **No** | — | — | Everything the user captures is stored on the device (SwiftData + AES-GCM media). No analytics service, no crash-reporting SDK, no server. |

Two things to state accurately in the description/review notes rather than the label:
- **Optional Cloud AI** (off by default): if the user enters *their own* Anthropic API key in Settings › AI, each capture they make while it is on is sent to `api.anthropic.com` under their own account. The developer receives nothing. The Privacy Center in-app says exactly this.
- **Purchases** are handled by StoreKit/Apple; the app only reads entitlement state.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set in Info.plist. Basis: the app uses only Apple-provided encryption — HTTPS via URLSession and CryptoKit AES-GCM for local data-at-rest protection — and no proprietary or third-party cryptography. You will still see the compliance question on first upload; answering per the above (uses encryption → only Apple OS/standard encryption → exempt) is consistent with the code. Confirm this yourself; I have not made a legal determination.

## Age rating questionnaire (basis: the actual app)

No: cartoon/realistic violence, sexual content/nudity, profanity, horror, alcohol/tobacco/drug references, mature themes, gambling, contests, unrestricted web access, medical/treatment info. **User-generated content: the user's own private content only, never shared or public.** Expected rating: **4+**.

## StoreKit

- Products: `moment_pro_monthly` (auto-renewable), `moment_pro_yearly` (auto-renewable), both in subscription group "MOMENT Pro"; `moment_pro_lifetime` (non-consumable). Create these in App Store Connect with exactly these IDs; prices are read from StoreKit (`displayPrice`), periods from `subscriptionPeriod`. The local `Moment/Resources/Moment.storekit` mirrors this for testing and is **not** bundled in the app.
- Entitlement is derived from `Transaction.currentEntitlements` on every launch and from `Transaction.updates`; nothing about Pro is persisted locally, so editing UserDefaults cannot unlock Pro. Revoked/expired transactions drop the entitlement on the next check.
- Handled: success, cancel, pending (Ask to Buy → returns without unlocking; `Transaction.updates` unlocks later), failure (message), restore (`AppStore.sync()`), verification failure (not unlocked). All verified transactions are `finish()`ed.
- Paywall shows: price + period per product, feature list, restore, the auto-renewal disclosure, Terms of Use (Apple standard EULA) and Privacy Policy link (once configured). No timers, no fake discounts. Free tier (100 memories, capture, search, reminders) is fully usable; viewing/export/delete are never gated.

## App Store metadata

- **Name:** MOMENT
- **Subtitle:** Never forget what matters.
- **Primary category:** Productivity. **Secondary:** Lifestyle.
- **Keywords:** `AI memory,personal memory,reminders,notes,life organizer,memories,productivity,people,plans`
- **Copyright:** © 2026 Rakshit Bargotra
- **Description:**

> MOMENT is your private AI memory for the things you don't want to forget.
>
> Throw in a screenshot, voice note, photo, link, thought, plan or conversation. MOMENT understands the context and remembers what matters.
>
> Plans. People. Promises. Ideas. Memories.
>
> Instead of organizing everything yourself, simply give it to MOMENT. Then MOMENT brings the right memory back when it becomes useful.
>
> "Sarah wanted those shoes."
> "Rahul said he'd send that contact."
> "You talked about Goa in December."
> "What was that restaurant we saved?"
>
> MOMENT helps you remember the things your brain shouldn't have to.
>
> • Capture anything: screenshots, photos, scans, PDFs, voice, text, links, or share from any app.
> • Understood on your iPhone: text recognition, speech and understanding run on-device. Everything you save stays on your iPhone, encrypted.
> • People, plans, promises and gift ideas are recognized and kept together, with the original source always one tap away.
> • Ask your memory anything and get an answer with its sources.
> • Useful reminders only — at most a couple a day, and never "come back to the app".
> • Optional Cloud AI for tougher captures, off by default, using your own key.
> • Export or delete everything, any time.
>
> MOMENT does its best to understand what you save; when it isn't sure, it says so and lets you correct it.
>
> Forget it. MOMENT will remember.

- **What's New (1.0):** First release.
- **Promotional text (optional):** Your private AI memory. Screenshot it, say it, share it — MOMENT remembers and brings it back when it matters.

## App Store screenshots (6.9" and 6.5" required)

Take them from the Release build with the fictional demo data (`Tools/run_sim.sh -demo -uitest` on a Debug build produces the same screens; the Release build has no demo seeding, so for marketing shots capture the same fictional content by hand or use the Debug demo build for screenshots only — screenshots are images, not the binary).

1. Home — "What matters today?"
2. Capture sheet — "Throw anything at MOMENT."
3. Capture result ("I remember this.") — "It actually understands."
4. Promise follow-up card / Promises list — "Never forget a promise."
5. Search with answer + sources — "Ask your memory anything."
6. Person profile — "Know what matters about your people."
7. Timeline — "Your life, remembered."

Demo content is fictional (Sarah, Rahul, Priya, Arjun; Goa, Bali, Tosaka).

## App preview storyboard (optional, 15–25 s)

0–3 s screenshot of a chat appears → 3–6 s "Analyzing… Reading text… Understanding context…" → 6–10 s "I remember this. Sarah wants New Balance 530" → 10–14 s Home card "Sarah's birthday is in 8 days. You have 1 gift idea saved." → 14–18 s typing "What did Rahul promise me?" → 18–22 s answer with source → end card "MOMENT — Never forget what matters."

## App Review notes (paste into App Store Connect)

> MOMENT is a private, on-device "memory" app. Users capture screenshots, photos, scans, PDFs, voice notes, text or links (or share them from other apps via the MOMENT share extension). The app reads text with Vision, transcribes voice with Speech, and an on-device engine (NaturalLanguage + rules) turns the content into memories: people, plans, promises, gift ideas, events and places. Every memory keeps its source, date and a confidence level, and can be edited or deleted. The Home screen resurfaces items when they become relevant (e.g. a saved gift idea before a birthday).
>
> **No account or login is required.** Nothing is uploaded by default; there is no server. An optional "Cloud AI" setting (off by default) lets a user paste their own Anthropic API key, in which case only the capture being processed is sent to Anthropic under the user's account.
>
> **To test the main flow:** complete the 4-screen onboarding (no permissions requested) → tap "+ MOMENT" → Text → type e.g. "Rahul said he'd send me the property contact tomorrow" → Save Moment. Home now shows a Follow-up card; the Search tab answers "What did Rahul promise me?" with its source. Try Voice (microphone + speech permission), Camera (scan), Screenshot or photo (picker, no photo-library permission), Link, File. Share a screenshot from Photos → Share → MOMENT; it appears under Review (Home strip / Vault tab) already understood.
>
> **Subscription:** Settings → MOMENT Pro. Free tier allows 100 memories; Pro removes the limit. Products: moment_pro_monthly, moment_pro_yearly (auto-renewing), moment_pro_lifetime (one-time). Restore Purchases is on the paywall. Sandbox purchases work with a sandbox tester.
>
> **Permissions** are requested only when the corresponding feature is used; Calendar and Contacts are optional and explicitly user-initiated from Settings / a person's profile. **Delete All Data** (Settings → Data) removes everything on the device. Face ID lock is optional.

## Signing & upload workflow

Signing is **working from the command line**: automatic signing with team `48TGY734WW` produced a Release archive and a distribution-signed IPA (`Apple Distribution: Rakshit Bargotra`, App Store provisioning profiles for the app, Share Extension and Widget, `get-task-allow = 0`, dSYMs included). Artifacts:

- `build/Moment-signed.xcarchive`
- `build/export/MOMENT.ipa` (+ `DistributionSummary.plist`)

What has **not** been done, because it needs your App Store Connect credentials: validation (`xcrun altool --validate-app`) and upload. Nothing has been uploaded or submitted.

1. **App Store Connect (you):** create the app record — name MOMENT, bundle ID `com.rakshitbargotra.moment`, SKU e.g. `MOMENT-IOS-1`, primary language English (U.S.), category Productivity, price Free, availability all territories (or your choice), subscription group "MOMENT Pro" with the three products above, App Privacy = Data Not Collected, age rating 4+, Privacy Policy URL, Support URL.
2. **Archive (already done; re-run after any code change):**
   ```sh
   xcodegen generate
   xcodebuild -project Moment.xcodeproj -scheme Moment -configuration Release \
     -destination 'generic/platform=iOS' -allowProvisioningUpdates \
     -archivePath build/Moment-signed.xcarchive archive
   xcodebuild -exportArchive -archivePath build/Moment-signed.xcarchive \
     -exportOptionsPlist Tools/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
   ```
   or Xcode: Product → Archive (Any iOS Device).
3. **Validate & upload (you):** either Xcode Organizer → Distribute App → App Store Connect → Upload, **or** command line with an App Store Connect API key:
   ```sh
   xcrun altool --validate-app -f build/export/MOMENT.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
   xcrun altool --upload-app   -f build/export/MOMENT.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
   ```
   (Set `destination` to `upload` in `Tools/ExportOptions.plist` to have `-exportArchive` upload directly instead.) Answer the export-compliance question as described above. Build 1 has never been uploaded; increment `CURRENT_PROJECT_VERSION` in `project.yml` before any *second* upload.
4. **TestFlight:** internal testers → run the checklist (install, onboarding, capture each type, share extension, widgets, search, people, promises, notifications, subscription + restore, offline, delete all, export, Face ID, dark mode, VoiceOver).
5. **Submission:** select the processed build, set **Manual release** (Version Release → "Manually release this version"), then Submit for Review — only when you say so.

## Moments layer (added)

- New model `MomentStory` (schema V1 still; the store was never shipped). New document type `.moment` (`UTExportedTypeDeclarations` + `CFBundleDocumentTypes`) so files sent via Messages/AirDrop open in MOMENT.
- Nothing new leaves the device automatically. Exports and `.moment` files go only through the system share sheet at the user's request; free tier allows 3 exports/month, Pro unlimited (viewing/receiving/reacting never gated).
- App Privacy label unchanged: **Data Not Collected** (no server, no upload).
- Photos: Memory Drop uses `PhotosPicker` (no library permission). Video export writes to a temporary file handed to the share sheet (no Photos-add permission needed).
- No music is bundled or generated.

## Social platform (added)

- Backend is **CloudKit** (`CloudKitBackend`): a Moment is a record in the owner's private DB custom zone; inviting people creates a `CKShare` (system `UICloudSharingController` — contacts, permissions, real `icloud.com/share/...` links). Invitees' contributions are written into the shared zone with their own identity; `memberIDs` on the root keeps "who was there". Public Moments are mirrored to the public DB for Discover. NOW posts, follows, reports and profiles live in the public DB; blocks/mutes/safety settings in the private DB. Media are `CKAsset`s produced by `MediaPipeline` (≤2048 px, EXIF stripped; video 1080p H.264, ≤120 s).
- Share links open the app through the CloudKit share flow (`SceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:)`); `moment://moment/<id>` deep-links a known Moment; a silent push (`CKDatabaseSubscription`) triggers a refresh and one local notification per Moment that grew ("3 new additions from people who were there" — never content).
- Offline: `UploadQueue` persists jobs to Application Support and retries with backoff; permission errors stop retrying and show as *Failed* with a Retry banner.
- Safety: block, mute, report (reason + details → `Report` records), private account, who-can-add/comment/message/mention, client-side abuse/spam filter on comments, NOW posts and DMs, contributor can remove their own media, owner can delete for everyone, member can leave.
- App Privacy label now: **Data Linked to You** — Name, User ID, Photos or Videos, Other User Content, Coarse Location (city-level place the user types); purpose App Functionality; no tracking. `PrivacyInfo.xcprivacy` updated accordingly.
- Free tier: every social feature is free and complete (feed, NOW, Moments, invites, DMs, Discover, reactions, comments). Pro still only gates private-memory count and story exports.
- CloudKit Dashboard prerequisites for the social features: record types are created on first write in the Development environment; before Production, deploy the schema and give the **Authenticated** role *Create/Read/Write* on `PublicMoment`, `Contribution`, `Now`, `Follow`, `Report` so strangers can join/contribute to public Moments and respond to "Anyone up?". Private/friends Moments never rely on this — CloudKit shares enforce access server-side.
- **Not built (needs infrastructure this repo doesn't have):** a Node/Postgres backend, admin console, web preview page and Universal Links (`moment.app/m/…`) — the client talks to one `SocialBackend` protocol so an HTTP backend can replace CloudKit without touching the UI; a web landing page needs a domain + AASA; a web preview page for share links (needs a domain + universal links; CloudKit's own share landing page is used instead), licensed music, server-side ML moderation (reports land in CloudKit for manual review), server-side push composition (local notifications on silent push instead).

## Location layer (added)

- `NSLocationWhenInUseUsageDescription` is asked only when the user opens *Nearby* or picks a venue. The fix is used once per screen load to run a radius query; it is never persisted, never attached to content, never shown to others. What is public is the **venue** a user deliberately picks (a café, a beach) — user-generated content, city-level `coarsePlace` derived from its area.
- Privacy label unchanged (Coarse Location, linked, app functionality). No precise-location collection: the app never sends the device coordinate to CloudKit; queries carry it only as a predicate parameter, which CloudKit does not store.
- CloudKit Dashboard: `PublicMoment.location` and `Now.location` must be indexed as *queryable* (Location type) for `distanceToLocation` queries; `PlaceClaim` needs Authenticated create/read and creator-only write. `verified` is set only from the Dashboard by a reviewer.

## Verification notes

- Social layer: unit tests for `FeedRanker`, `MomentTimeline`, `ContentModeration`, `UploadQueue` (offline persistence, resume, permanent failure), `MediaPipeline` and end-to-end flows on `InMemoryBackend` (create → invite → other person adds their side → stranger rejected; accept invite link; feed ranking + block; reactions/comments/moderation; NOW → save to Moment; safety settings incl. who-can-comment; DMs with Moment replies; profile/friendship; delete/leave ownership). **Last completed run (2026-09-15): 18 of 19 social tests passed; the one failure was a test asserting an absolute analytics count (counts persist in UserDefaults across tests) and was changed to a delta — that fix, plus the who-can-comment test added afterwards, have not been re-run.** The pre-existing 74 tests passed in the same session except two `ScaleTests` timing thresholds that failed only because the host load average was >150.
- **Not completed on 2026-09-16:** the full unit suite and the rewritten UI suite (`Tests/UI/MomentUITests.swift`, 10 tests + screenshot tour). After a reboot this Mac's CoreSimulator service stayed wedged (`simctl boot/install` hang, "Data Migration Failed", "(ipc/mig) server died", xcodebuild intermittently reporting "iOS 18.2 is not installed") while Xcode.app, Chrome and Codeium kept the load average at 100–400. `xcrun simctl runtime match set iphoneos18.2 22D8075` fixed the destination lookup; the hang did not clear. Run on an idle machine after quitting Xcode/Simulator: `xcodebuild -project Moment.xcodeproj -scheme Moment -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test`.
- Signed Release archive and App Store IPA export (`build/export/MOMENT.ipa`) succeeded on 2026-09-16 with the new entitlements: distribution profile carries `aps-environment: production` and `iCloud.com.rakshitbargotra.moment` (Xcode registered the container and push capability on the App ID via `-allowProvisioningUpdates`).
- **CloudKit on a real device is unverified from this Mac** (no signed-in iCloud account available to `xcodebuild`). The `CloudKitBackend` compiles against the same protocol the in-memory backend passes; first device run needs the container created (Xcode → Signing & Capabilities → iCloud) and, before public release, the CloudKit Dashboard schema deployed to Production (Development schema is created automatically on first write; Production requires "Deploy Schema Changes").

- Moments layer: 84 unit tests pass (StoryComposer, recaps, core-memory detector, command routing, `.moment` package round-trip and merge, image + H.264 video export, free-tier export budget). **The UI test for the Moments flow (`testMomentsHubCreatesMonthRecapAndOpensEditor`) and the updated screenshot tour have not completed on this Mac** — the UI test runner repeatedly failed to initialize under host load (load average 100–300 from other work and simulator cache rebuilds after the disk filled). Run when idle: `xcodebuild -project Moment.xcodeproj -scheme Moment -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:MomentUITests test`. The 10 pre-Moments UI tests passed on the previous build.

- Screenshot tour (20 screens: Home, Vault, Search + results, People, Person, Memory, Capture, Result, Settings, Privacy, Paywall, Promises, Gifts, Plan, Voice, Onboarding) passed on iPhone 16 Pro in light mode; Home/capture also checked in dark mode and at XXL Dynamic Type.
- **Not completed:** the same tour on iPhone SE (3rd gen). This Mac has ~1.4 GB free; booting a second simulator needs ~3 GB and the run died with "no space left on device". Free space (`~/Library/Developer/Xcode/iOS DeviceSupport` is 19 GB of regenerable device symbols) and run: `xcodebuild -project Moment.xcodeproj -scheme Moment -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -only-testing:MomentUITests/MomentUITests/testScreenshotTour test`. All layouts use Dynamic Type and wrapping stacks, so clipping risk on the 375-pt width is low, but it is unverified.
- Run only one `xcodebuild` at a time on this machine; parallel runs pushed the load average past 100 and produced meaningless timings.

## Blockers requiring your action

1. **Privacy Policy URL required** — set it in App Store Connect and in `Moment/Resources/Info.plist` → `MomentPrivacyPolicyURL` (the paywall and Settings link to it).
2. **Support URL required** — set in App Store Connect and `MomentSupportURL` in Info.plist. (No website exists in this project, so I could not create one.)
3. Create the App Store Connect app record and the three in-app purchase products with the exact IDs above.
4. Validate and upload `build/export/MOMENT.ipa` (needs your Apple ID / ASC API key).
5. Upload screenshots (6.9" and 6.5") — capture from the build using the fictional demo content.
6. Answer the export-compliance question on first upload (basis above).
7. Submit for Review (manual release selected).
