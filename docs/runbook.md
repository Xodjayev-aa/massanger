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
| Vercel Hobby project named `messengerx-uz` | Free HTTPS website at `https://messengerx-uz.vercel.app` (site root `/`) | Not created from this workspace. On 25 September 2026 that hostname returned `DEPLOYMENT_NOT_FOUND`. GitHub Pages `/massanger/` is retired (404). Vercel is not a worker. If the project name is taken, stop and ask before picking another. See [vercel.md](vercel.md). |

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
   `https://messengerx-uz.vercel.app`. Allow
   `https://messengerx-uz.vercel.app`,
   `https://messengerx-uz.vercel.app/` and
   `https://messengerx-uz.vercel.app/**`. Remove the retired GitHub Pages
   redirect if it is still listed. Allow the native
   `com.messengerx.app://login-callback` **only after** native schemes are
   installed and tested — there is no signed public Android installer yet.
   Avoid wildcard production redirects. Auth → Providers → Google: enable the
   basic web OAuth client and register Supabase's displayed
   `https://<ref>.supabase.co/auth/v1/callback` with Google. That Google
   redirect URI does **not** change to the Vercel address. Google's
   Authorized JavaScript origin **does** change to
   `https://messengerx-uz.vercel.app` (no path). Click-by-click steps are in
   [vercel.md](vercel.md). Configure an external consent screen if Google
   requires one. Gmail/Drive access is not requested. Telegram OIDC
   configuration is in [telegram-sign-in.md](telegram-sign-in.md); leave
   `TELEGRAM_OIDC_ENABLED=false` until its callback is live-tested.
3. Hosted Edge Functions are set to `MESSENGERX_ENV=production`. Configure
   **private** Function secrets `SEAL_KEY` (32 random bytes/64 hex digits),
   `BRIDGE_TOKEN` and `BRIDGE_HMAC_SECRET` (different random values, at least
   32 characters each), plus `ALLOWED_ORIGINS=https://messengerx-uz.vercel.app` (an **origin**, with no
   path and no trailing slash). Supabase provides `SUPABASE_URL`,
   `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` in its hosted runtime;
   never put the service-role key in GitHub repository variables, Vercel, or Flutter.
   If the Vercel project name is taken, stop and ask before using another origin.
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

The public site is a **Vercel Hobby** static deploy at the domain root, not
GitHub Pages. `https://xodjayev-aa.github.io/massanger/` returns 404 and the
Pages workflow has been removed so it cannot publish `/massanger/` again.
Follow [vercel.md](vercel.md) exactly: project name `messengerx-uz`, root
directory `apps/mobile_app` (or the repository root — both `vercel.json` files
call the same script), install/build commands from that file, and only
`SUPABASE_URL` plus the public anon/publishable key as environment variables.
The build script installs Flutter 3.24.5 because Vercel does not provide it,
compiles `--base-href=/`, and refuses service-role, Google, and Telegram
secrets if they are present in the build environment.

This repository does **not** create the Vercel project. A merge to `main` does
not deploy until the Vercel project is connected, and it does not apply
Supabase migrations. Do not claim `https://messengerx-uz.vercel.app` is live
until that hostname serves the MessengerX sign-in page rather than
`DEPLOYMENT_NOT_FOUND`. If Vercel will not accept the project name, stop and
ask before choosing another.

Smoke test the public site from two **different** browsers/devices only after
that deploy and the dashboard changes in [vercel.md](vercel.md): Google
sign-in, token refresh, logout, chats, image and WAV voice, RLS on another
user's private rows, realtime updates, and browser reload of `/`, `/sign-in`,
`/chats` and `/chats/<id>` (the app must load; a Vercel 404 means the rewrite
failed). Install the PWA from Chrome and, on iPhone, use Add to Home Screen.
That PWA is the $0 iPhone option. There is no signed public Android installer
and no App Store app. Run a second login after a day, check service pause
behavior and restore data from a backup in staging. Vercel still cannot run
the TDLib worker.

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

- **Web:** the Vercel PWA can be installed on modern phones through the browser
  after the real HTTPS site and Auth setup are working. Test install separately;
  the installed PWA is not an offline chat archive, and no native store listing
  is implied. On iPhone this PWA is the $0 option.
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
