# MOMENT web

Static site — no server, no build step. Deploy the `web/` folder to any static host (Vercel, Netlify, GitHub Pages, S3).

- `index.html` — landing page. `privacy.html`, `support.html` — the two URLs App Store Connect requires (replace `REPLACE_ME@example.com`).
- `m/` — share-link fallback: `https://<domain>/m/<momentID>` opens `moment://moment/<id>`, or points to the App Store. `u/` — the same for a person's MOMENT ID (`/u/<id>`).
- `dashboard/` — venue owner dashboard. Reads the **public** CloudKit database with CloudKit JS; owners sign in with the Apple ID they use in the app and see their claimed places, Moments/people counts, live status, and a printable QR. Configure `dashboard/config.js` with a CloudKit API token (CloudKit Dashboard → API Access → Tokens). Verification badges are set only in the CloudKit Dashboard.
- `.well-known-apple-app-site-association.json` — rename to `.well-known/apple-app-site-association` (no extension, served as `application/json`) and add `applinks:<domain>` to the app's Associated Domains entitlement to make `/m/*` and `/u/*` Universal Links.
- Replace `id0000000000` with the real App Store id once the app record exists.
