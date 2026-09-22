# Going live — the runbook

What exists: a native **iPhone app** (this repo), a **web client** (`web/app`, installable PWA — this is how Android users get in today), a **website** (`web/`), and a **relay** (`relay/`) anyone can run. There is no MOMENT backend to deploy; the only servers you run are relays and the static site.

Order of operations, with what each step needs from you (~2–3 weeks if nothing is blocked by review):

## 0. Accounts (day 1)
- **Apple Developer Program** ($99/yr) on the team that owns bundle id `com.rakshitbargotra.moment` (team `48TGY734WW` is already in `project.yml`). Agree to the latest Paid Apps agreement in App Store Connect — required before any in‑app purchase works.
- A **domain** (e.g. `moment.social`). Point it at Vercel (website + web app) and a subdomain at the relay (`relay.moment.social`).
- **Google Play Console** ($25 one‑off) only when you do step 6.

## 1. Relay (day 1–2)
Any $5–10 VM (Hetzner/Fly/Render) with Node 20:
```
git clone … && cd relay && npm install
DATA=/var/lib/moment/events.jsonl RETAIN_DAYS=365 PORT=7447 node server.js   # run under systemd/pm2
```
Put Caddy in front for TLS: `relay.moment.social { reverse_proxy localhost:7447 }` → `wss://relay.moment.social`.
Then set `NetworkMode.defaultRelays` in `Moment/Services/SettingsStore.swift` to `["wss://relay.moment.social"]` so fresh installs have one relay out of the box (they can add more; you can run more). The relay stores signed events only; it cannot read private Moments, likes, or chats. Retention and abuse: `RETAIN_DAYS`, plus `report` events arrive here — read them.

## 2. Website + web app (day 2)
`web/` is static. Deploy on Vercel (project already connected): root = `web`. Check:
- `web/.well-known-apple-app-site-association.json` → serve at `/.well-known/apple-app-site-association` with `Content-Type: application/json` and your **team id + bundle id** (universal links for `https://moment.social/m/<id>`).
- `web/index.html`: replace `apps.apple.com/app/id0000000000` with the real App Store id once step 4 gives you one.
- `web/support.html`: real support email. `web/privacy.html`: keep accurate — it's what you submit to Apple.
- `web/app/`: MOMENT Web. Set a default relay in `web/app/app.js` (`relays()` fallback) so first‑run works.

## 3. App Store Connect record (day 2–3)
1. Create the app: bundle id above, name **MOMENT**, primary category Social Networking, secondary Lifestyle.
2. **In‑app purchases** (must match the ids in `Moment/Resources/Moment.storekit` exactly):
   - `moment_pro_monthly`, `moment_pro_yearly` (auto‑renewable, group "MOMENT Pro"), `moment_pro_lifetime` (non‑consumable)
   - `creator.30d.t1` / `t2` / `t3` — **non‑renewing subscriptions** (₹199 / ₹499 / ₹999 tiers)
   - `creator.tip.small` / `medium` / `large` — **consumables**
   Each needs a display name, description and a review screenshot. Submit them *with* the first build.
3. **Age rating**: Meet (dating) and user‑generated content push this to **17+**. Answer "Unrestricted Web Access: No", "Mature/Suggestive: Infrequent", and mark the dating features. Meet is opt‑in and 18+ in‑app, which is what reviewers look for.
4. **App Privacy** (the nutrition label). Honest answers given the code: *Data not collected* for everything **except** purchases (Apple handles them) and, if you keep the optional local analytics, "Analytics — not linked to you, on‑device". Location is used but never sent to you — still declare "Location: used for app functionality, not linked". Photos: user content, not collected by you. No tracking.
5. **Review notes** (this is what gets a UGC + dating + payments app through first time):
   - Demo account: none needed — use *Settings → Sample data* (DEBUG only, so instead ship a TestFlight build with `-demo` semantics or record a 60‑s video walkthrough and attach it).
   - Point to: block/report on every profile and Moment; content moderation on comments (`ContentModeration`); Meet is opt‑in, 18+, mutual‑match only; creators' payouts are handled off‑platform (explain the 30‑day non‑renewing products and that Apple's cut is taken); no external payment links.
   - Explain the decentralised model in two sentences so "where is your server?" doesn't stall review.

## 4. Build, TestFlight, submit (day 3–7)
```
xcodegen generate
xcodebuild -project Moment.xcodeproj -scheme Moment -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Moment.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Moment.xcarchive -exportOptionsPlist Tools/ExportOptions.plist -exportPath build/export
xcrun altool --upload-app -f build/export/MOMENT.ipa -t ios -u <apple id> -p <app-specific password>
```
(or Xcode → Product → Archive → Distribute). Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` per upload.
- TestFlight: internal testers first (you + 5 friends on two phones in one room to see the mesh work), then an external group (needs a short beta review).
- Before submitting: run on a **real device** with the real relay — CloudKit mode is optional now, but if you keep it selectable, the CloudKit Dashboard needs the record types deployed to Production (`RELEASE.md` lists them).
- Screenshots: 6.7" and 6.1" sets. The screenshot tour test writes them to `build/screens/` (`testScreenshotTour`).

## 5. Payouts to creators (before the first creator earns)
Apple pays you ~30–45 days after month end. `Earn` shows creators 80 % of net. You need a monthly job: export App Store Connect *Sales and Trends* for the `creator.*` products, join with the `plan` records' `payoutHint` (UPI/PayPal/IBAN) and the subscription/tip records (which carry transaction ids), pay out, keep the ledger. Start manual (spreadsheet), automate later. Say the 80 % and the timing in `web/privacy.html`/terms.

## 6. Android
Today: **MOMENT Web** at `moment.social/app` — install to home screen, it runs as a PWA (Tonight, NOW, public Moments, invite links). Same keys/protocol, so it interoperates with iPhone users on the same relays.
Play Store listing: wrap the PWA as a **Trusted Web Activity** (Bubblewrap: `npx @bubblewrap/cli init --manifest https://moment.social/app/manifest.webmanifest`) — a real Play listing in a day, no native code. Limits: no Multipeer mesh, no StoreKit (Play Billing needed for creators), no Keychain (keys live in the browser's storage — back up via Settings → Copy secret).
Native Android (Kotlin/Compose) is the real second product: the protocol (`SignedEvent`, relay frames, AES‑GCM/X25519 sealing, geo cells) is fully specified in `relay/README.md` + `web/app/moment.js` and is small; the UI is the work. Budget 6–10 weeks for parity with the iPhone app.

## 7. Launch day
- Seed the relay: create 5–10 real public Moments in your city (Rituals work best — Friday sunset, Sunday run).
- The growth loop is the **Replay video** share + the QR on the table. Every Replay ends with the invite link; every event host gets a QR.
- Watch: relay disk/retention, `report` events, App Store review replies, TestFlight crash logs (no third‑party crash SDK by design).

## Costs (monthly, small)
Relay VM $5–10 · Vercel free · Apple $8 · domain $1. Nothing scales with users except relay storage (events are small; media is thumbnails).
