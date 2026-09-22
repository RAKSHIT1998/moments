# Selling on MOMENT — how it works, and what it costs to run

Creators sell three things: **sets** (photos/clips, free or priced), **time** (video call, voice call, custom), and **subscriptions + tips** (already in the app). Creators set every price and can withdraw anything at any time.

## The 10%

MOMENT keeps **10%** of what a creator charges — but only on its own rail.

| Rail | Who takes what | Creator keeps on ₹1,000 |
|---|---|---|
| **Card checkout (web)** | MOMENT 10%, then the creator's own processor (~3–8% + fees) | **₹900** before processor fees |
| **Apple in‑app purchase** | Apple 30% first, then the app's 80/20 split | **₹560** |

This is why the web app matters: **a 10% take rate is arithmetically impossible through Apple IAP**, because Apple takes 30% before anyone else. `CreatorEconomics.creatorTake(_:rail:)` computes both and the Studio screen always names which rail it's quoting. Never show one number for the other.

Since the 2025 US injunction, a US‑storefront iOS app may link out to external checkout without Apple's commission; `SettingsStore.webCheckoutEnabled` + `checkoutBaseURL` drive that path, and it is **off by default** because it is not allowed everywhere.

## How paid content stays the creator's

There is no MOMENT server holding anyone's photos.

- A set's **shop window** (title, blurb, price, one cover the creator chooses) is a public signed event.
- The **contents** are AES‑GCM sealed under a per‑set key that lives on the creator's phone.
- When someone pays, their phone publishes a `vaultBuy` event; the creator's phone answers with a `vaultKey` event containing that set key **sealed to the buyer's X25519 key**. Relays and every other device store the bytes and can't open them (`DecentralizedStorefrontTests` proves this with a third phone).
- **Withdrawing a set rotates the key.** Existing buyers keep what they downloaded; nothing new decrypts. That is the honest limit of any distributed system: you can stop new access, you cannot un‑give a file someone already holds.

Bookings follow the same rule: only the creator can accept or decline; either side can mark done or refunded; accepting mints the room id both sides see.

## What this design cannot do

- **It cannot force a takedown.** Signed events replicate. If you need guaranteed removal (a legal requirement for most paid-content businesses), you need the media served from storage you control — keep relays for metadata and put the media behind your own signed URLs.
- **It cannot verify anyone's age or identity.** That's an external process (see below).

## If the content is adult

This changes the product, not the code:

1. **No iOS app.** App Store rule 1.1.4 forbids pornography; OnlyFans has no iOS app for that reason. The PWA at `web/app` is the product; the iPhone app stays general‑audience.
2. **Payments**: Stripe, PayPal and Apple all prohibit adult content. You need a specialist processor (CCBill, Segpay, Epoch) — higher fees, chargeback reserves, slower onboarding.
3. **Age verification is now law** in the UK (Online Safety Act) and several US states: verified 18+ for viewers, not a checkbox.
4. **Performer records**: US 18 U.S.C. §2257 requires verified ID and consent records for every performer, kept and auditable. Creator onboarding must capture them.
5. **Moderation is not optional**: CSAM detection and reporting duties, non‑consensual imagery takedowns, DMCA agent registration. This is staffing, not a feature flag.
6. Payouts: KYC on creators, tax forms, and a ledger you can defend.

None of that is in this repo, and none of it should be faked. If you go this way, the order is: processor → age/ID verification vendor → moderation + takedown process → then launch.

## What's built now

- `VaultSet` / `VaultItem` / `VaultPurchase` — sets, sealed items, proof of purchase.
- `BookingOffer` / `Booking` — selling time, request → accept → room → done.
- `CreatorLinks` — Instagram, X, TikTok, YouTube, website on the profile (self‑claimed; we don't verify them).
- **Studio** (Profile → Sell your photos and your time): earnings this month with the rail named, sets grid, offers, bookings, handles.
- **Shop** on any creator's profile: free sets open, paid sets blurred with the price on the lock, time to book.
- Three backends: in‑memory (demo), CloudKit, and the mesh with the sealed‑key handoff.
- Fee maths and the paywall are covered by tests, including a third phone that holds every byte and can open nothing.

## What's still missing before money moves

1. A **payment processor integration** (web checkout + webhook that records the purchase reference). Today `buySet(_:reference:)` accepts the reference; nothing calls a processor.
2. **Payout runs** — see `LAUNCH.md`; the ledger exists, the transfers don't.
3. **Video calls**: bookings mint a room id, but there's no media layer. That needs WebRTC (LiveKit or similar); signalling can ride the relay as ephemeral frames, the media cannot.
4. **Creator onboarding/KYC** and, for adult content, everything in the section above.
