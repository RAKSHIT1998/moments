# MOMENT web

Static site — no server, no build step. Deploy the `web/` folder to any static host (Vercel, Netlify, GitHub Pages, S3).

- `index.html` — landing page. `privacy.html`, `support.html` — the two URLs App Store Connect requires (replace `REPLACE_ME@example.com`).
- `m/` — share-link fallback: `https://<domain>/m/<id>` opens the app, or points to the App Store. `u/` — the same for a person's MOMENT ID (`/u/<id>`).
- `app/` — **MOMENT Web**, the PWA. Same protocol as the iPhone app: Ed25519 identity in the browser, the app's exact canonical signed-event bytes, AES-GCM opening of sealed sets. It is a *reader* — browse creators, unlock what you've paid for, keep your identity. Posting, selling, calls and chats are the app. It also cannot block screenshots the way iOS can, and says so on every screen that shows paid media.
- `.well-known-apple-app-site-association.json` — rename to `.well-known/apple-app-site-association` (no extension, served as `application/json`) and add `applinks:<domain>` to the app's Associated Domains entitlement to make `/m/*` and `/u/*` Universal Links.
- Replace `id0000000000` with the real App Store id once the app record exists.
