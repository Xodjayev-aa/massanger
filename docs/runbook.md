# MessengerX launch & operations checklist

**Updated 25 September 2026. This is a recipe, not a deployed service.** Merging
source to `main` does not create a website, hosted database, OAuth provider, TDLib
worker or signed mobile binary. Do not announce a public launch until the live
checks below pass. Budget is **$0**, without Oracle or an always-on personal PC.

## 1. What you need to provide (in provider dashboards, not in chat)

| Needed | Purpose | Cost / limitation |
| --- | --- | --- |
| A Supabase Free project | Hosted Postgres, RLS, Storage, Auth, Edge Functions, Realtime | Free within quotas; projects may pause after a week of inactivity. Free projects lack managed daily backups: export a tested backup of data and private TDLib session storage yourself. |
| Google OAuth **web** client | Optional Google sign-in via Supabase Auth | Basic `openid email profile` only. No Gmail or Drive scope and no account-age claims. |
| A Telegram BotFather login client/secret | Optional standalone Telegram **OIDC approval** sign-in | Configure only in Supabase Auth as `custom:telegram`; does not create a TDLib user session. See [telegram-sign-in.md](telegram-sign-in.md). |
| A Telegram **API ID/hash** from `my.telegram.org` | Personal-account TDLib linking via phone, code, optional 2FA | API hash belongs only on the worker, never in the web/mobile app. |
| A durable Linux host running native TDLib and Node | Sync Telegram chats and deliver A+C offline notices through Saved Messages | **No verified $0 host has been provisioned** that guarantees always-on execution *and* encrypted, persistent private TDLib files. A serverless web host or free sleeping instance does not substitute for this. |
| GitHub Pages configured for this repo | Free HTTPS website at `https://xodjayev-aa.github.io/massanger/` | Public site is opt-in; Pages does not provide the database or worker. A custom domain is optional and is not free by default. |

**Unfulfilled product requirement:** the direct in-app Telegram **phone/code
identity sign-in** (without first using Google or Telegram OIDC) is *not*
implemented. The phone/code wizard authenticates a TDLib session only **after**
a Supabase user signs in. OIDC is an additional choice, not an equivalent of
in-app code sign-in; do not claim otherwise. Google and Telegram OIDC logins may
create separate MessengerX accounts: do not auto-merge identities by username,
email or phone. The static site can be deployed without a worker, but Telegram
chat and offline notices then **will not work**.

## 2. Verify source before provisioning

```bash
npm ci
npm run check                         # PGlite migrations/RLS, seed, edge config, bridge simulator, TS
bash tools/verify-client.sh           # requires Flutter SDK, analyzer, tests, placeholder release web build
```

GitHub CI checks Flutter web and Android debug compilation with a placeholder
URL/key; it **does not** talk to hosted Supabase, Google, Telegram, iOS/Xcode
or a physical phone. Review the source and
migrations before granting a real service-role key. Use a new staging project
before production. No one has verified the real TDLib binary or its runtime
memory/storage demands in this environment.

For local development, install Supabase CLI + Docker + Flutter, then run `make
env && make db-start && make db-reset`. The template `.messengerx/app.json` and
`supabase/functions/.env.local` are private/ignored. Fill them from `supabase
status`; use `flutter run -d chrome --web-port 5050
--dart-define-from-file=../../.messengerx/app.json` from `apps/mobile_app`.
`make bridge` uses the **memory simulator** by default. Never copy local test
keys or seed data to production.

## 3. Hosted database, OAuth and functions (operator actions)

1. In your own Supabase Dashboard, create a **Free** project. Keep the database
   password, legacy service-role/secret key and JWT signing material private.
   Use the Supabase CLI authenticated **on your own trusted machine** to link
   the project: `supabase link --project-ref <your-project-ref>`, then
   `supabase db push`. This applies migrations `00001` through `00016`; do **not**
   run `supabase db reset` on production (it drops data), and do not import
   `supabase/seed.sql` into live users' data. Check every migration result and
   inspect RLS, grants, Storage buckets and Realtime publication in Dashboard.
2. Auth → URL Configuration: set the site URL to
   `https://xodjayev-aa.github.io/massanger/` (or your eventual **real** HTTPS
   host); allow the precise website callback and the native
   `com.messengerx.app://login-callback` **only after** native schemes are
   installed. Avoid wildcard production redirects. Auth → Providers → Google:
   enable the basic web OAuth client and register Supabase's displayed
   `https://<ref>.supabase.co/auth/v1/callback` with Google. Configure an
   external consent screen if Google requires one. Gmail/Drive access is not
   requested. Telegram OIDC configuration is in
   [telegram-sign-in.md](telegram-sign-in.md); leave
   `TELEGRAM_OIDC_ENABLED=false` until its callback is live-tested.
3. Hosted Edge Functions are set to `MESSENGERX_ENV=production`. Configure
   **private** Function secrets `SEAL_KEY` (32 random bytes/64 hex digits),
   `BRIDGE_TOKEN` and `BRIDGE_HMAC_SECRET` (different random values, at least
   32 characters each), plus `ALLOWED_ORIGINS=https://xodjayev-aa.github.io` (an **origin**, without the
   `/massanger/` path). Supabase provides `SUPABASE_URL`,
   `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` in its hosted runtime;
   never put the service-role key in GitHub repository variables or Flutter.
   If you use another site, change the CORS origin to match it exactly.
   **Production functions now refuse wildcard CORS or plaintext Telegram login
   payloads**; provision these secrets *before* exposing the functions. Store
   them in private operator storage and configure the identical three keys on
   the worker. `SUPABASE_JWT_SECRET` is optional for a hosted project using
   asymmetric user JWTs: `requireUser` validates tokens with Supabase Auth's
   `getUser()` and rejects non-user roles.
4. Run `supabase functions deploy telegram-link`, `telegram-send` and
   `telegram-ingest` (or `make deploy`, which also deploys the read-only legacy
   `account-age-gate` status route). In the hosted Functions settings verify
   `telegram-link`/`telegram-send` have **JWT verification on**;
   `telegram-ingest` has platform verification **off** because it requires
   both the private bridge bearer and signed HMAC with replay protection.
   Never switch off its application-level check or place those credentials in
   any client. The local `supabase/config.toml` is *not* the hosted Auth config.
5. Test with two genuine users. Inspect `profiles.access_state`, auth identity
   provider, chat membership restrictions, URL-signed private media, and the
   post-link cross-account uniqueness guard. Verify that another user cannot
   read a private chat, Telegram queue, login request or media path. Check
   storage limits and set a regular, restorable backup/export plan within
   Supabase Free constraints. A PGlite pass is necessary, not sufficient.

## 4. Publish the website (after backend checks, not just merge)

The repository has an opt-in GitHub Actions Pages job. In GitHub **Settings →
Pages**, set source to **GitHub Actions**. In **Settings → Secrets and variables →
Actions → Variables**, set `SUPABASE_URL` to the hosted HTTPS project URL,
`SUPABASE_ANON_KEY` to the **public** publishable/anon key and
`TELEGRAM_OIDC_ENABLED` to `true` **only if** real hosted Telegram OIDC passed
[its smoke test](telegram-sign-in.md). Do not set `LAUNCH_APPROVED=true` until
the production checks and worker trial are done. These repository **variables**
are compiled into every public website build: no secrets belong there.

After the PR has merged, when you are ready, set `LAUNCH_APPROVED=true` and in
GitHub Actions run **CI → Run workflow → main** manually. The `pages` job builds
with `--base-href=/massanger/`, `WEB_REDIRECT_URL` including the base path, and
a SPA 404 fallback; it publishes the site at
`https://xodjayev-aa.github.io/massanger/`. A Pages URL without a functional
hosted Supabase project is just a shell. Arena's GitHub integration in this
workspace cannot dispatch Actions workflows; the repository owner must use
the GitHub Actions UI to run this opt-in publish job.

Alternatively, Vercel Hobby can host the built static `apps/mobile_app/build/web`
with `apps/mobile_app/vercel.json` SPA rewrites and a free `vercel.app`
subdomain, but Vercel cannot run TDLib permanently. It needs a real Flutter
build in CI/a trusted build machine plus a Vercel account; do not upload the
service-role key as a Vercel environment variable. This repo does **not**
automatically provision or publish to Vercel.

Smoke test the public site from two **different** browsers/devices: Google and
Telegram identity sign-in (if enabled), token refresh, logout, chats, image and
WAV voice, RLS on another user's private rows, realtime updates and browser
reload on `/massanger/chats/...`. Run a second login after a day, check
service pause behavior and restore data from a backup in staging.

## 5. Personal TDLib bridge and A + C notifications

**Only use a host that actually stays online and preserves a private writable
volume across restarts.** The pinned TDLib JSON library is built from
`services/telegram_bridge/Dockerfile`; building the container image does not
host it. `infra/docker-compose.yml` mounts a named volume and keeps the admin
port on the host loopback; `infra/messengerx-bridge.service` is an optional
native systemd unit. These are examples for a host you have chosen, **not** a
$0 hosting offer. Do not choose Oracle or an always-on personal computer.

On the chosen host, install Node 22 (or use the Dockerfile), build the worker
with `npm ci && npm run build:bridge`, configure a private environment based on
`services/telegram_bridge/.env.example`:

- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` **on the worker only**;
- `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` from the operator's Telegram API app;
- matching `SEAL_KEY`, `BRIDGE_TOKEN`, `BRIDGE_HMAC_SECRET` from §3;
- `TDLIB_DB_KEY` (32 random bytes in base64; keep it with encrypted backups);
- `MESSENGERX_ENV=production`, `BRIDGE_TRANSPORT=koffi`, the verified
  `TDLIB_LIBRARY_PATH`, an explicit **persistent absolute** `BRIDGE_DATA_DIR`
  outside `/tmp`, and loopback-only `BRIDGE_HEALTH_HOST=127.0.0.1` for the
  native unit. Hosted startup rejects missing key material, temporary session
  paths, HTTP Supabase, simulator transport and direct RPC ingress. In Compose, its port is
  published to **127.0.0.1** on the host even though the container binds 0.0.0.0.

Protect session files (mode 0700), use a dedicated unprivileged user, keep the
admin wake port private and monitor disk space. Back up **both** TDLib's
persistent directory and its encryption key; loss requires reauthentication.
Never share one TDLib session directory across workers. After start, check
`/readyz` privately, link **your own** Telegram account using phone + code and
optional 2FA, restart the worker, and verify the linked session survives.
Then try sending and receiving a real message with a Telegram-only person using
an exact public `@username`. Test muted/read/duplicate notices and Saved
Messages with the app in foreground, background and offline on actual phones.
Telegram may suppress an OS notification for a self-sent Saved Messages item:
this is not APNs/FCM and does not promise an OS banner. App banners only exist
while the app is running; no notice deep-link tap-through is implemented.

**No verified $0 durable worker has been identified.** If one is unavailable,
the production choice is to defer Telegram sync/offline notices or change the
budget requirement openly, not to deploy a sleeping/ephemeral worker and call
it reliable. Replacing native TDLib with a Bot API or a serverless function
cannot send as each user or retain their private chats.

## 6. Installable app limitations

- **Web:** the Pages PWA can be installed on modern phones through the browser
  after the real HTTPS site and Auth setup are working. Test install/offline
  behavior separately; no native store listing is implied.
- **Android:** the tracked project includes microphone/Internet permission,
  `com.messengerx.app://login-callback`, an aligned application ID and API 23+.
  CI attempts a placeholder-config **debug** build. For a public binary,
  provision a protected release signing key, configure Gradle, build a
  **real-config signed** APK/AAB and test OAuth, media and Telegram on devices.
  CI's debug build is not that release. Sideloading is free but has OS warnings;
  publishing through Google Play may require its registration fee.
- **iOS native:** the tracked project includes an OAuth URL scheme and media
  usage descriptions, but still needs a Mac/Xcode for compiling and device tests.
  Public App Store/TestFlight distribution normally requires the paid Apple
  Developer Program, incompatible with a strict $0 requirement. On iOS,
  use the **PWA** for the $0 option rather than claiming a public native build.

## 7. Gate for saying “ready”

Do not mark this repository or a PR as a live product until **all** relevant
items are true: migrated hosted database with RLS tests and backups; real OAuth
callbacks and account recovery; HTTPS public PWA that signs in on two devices;
verified persistent native TDLib host; matching sealed/HMAC secrets; successful
real Telegram send/receive and new username lookup; A+C device notification
checks; Android signed build/device tests (if advertised); native iOS membership
and device tests (if advertised). The *standalone phone/code identity* option
still needs its own implementation and security review even if Telegram OIDC
is working. Keep that gap visible to users.
