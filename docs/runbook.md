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
   `supabase db push`. This applies migrations `00001` through `00017`; do **not**
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
4. Run `supabase functions deploy telegram-link`, `telegram-send`,
   `web-push-send --no-verify-jwt` (see §5b) and
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

## 5b. Browser notifications ($0, no worker)

This is the second offline-notice path, and the only one that needs **no machine
of ours running at all**. Instead of a worker pushing into Telegram, the
browser's own push service holds the connection and a service worker draws the
notification. There is no FCM project, no OneSignal account and no Apple
Developer Program involved: the site's own origin is the identity and VAPID is
the signature.

Like Telegram notices, it only tells someone *"you have a MessengerX message"*.
It is not Telegram sync, and it does not ask the operating system for anything
the user has not allowed.

### What to configure

1. **Apply migration `00017_web_push.sql`** with the rest of the migrations
   (§3). Without it the app hides the switch rather than showing a broken one.

2. **Generate a VAPID key pair once** — this is the identity the push services
   verify, and rotating it invalidates every existing subscription:

   ```bash
   npx --yes web-push-send generate-vapid-keys --json
   ```

3. **Set the function secrets** (dashboard or CLI; never in a Git commit):

   ```bash
   supabase secrets set \
     WEB_PUSH_VAPID_PUBLIC_KEY=<publicKey> \
     WEB_PUSH_VAPID_PRIVATE_KEY=<privateKey> \
     WEB_PUSH_VAPID_SUBJECT=mailto:you@example.com
   ```

   `WEB_PUSH_VAPID_SUBJECT` must be a `mailto:` or `https:` URI — every push
   service requires a contact address and rejects a request without one. The
   public key is public by design (the browser sends it back in every request as
   `k=`), but set all three together: the function refuses a half-configured
   deployment instead of failing silently on the first message.

4. **Deploy the function.** It is the one function that also has no user JWT on
   the scheduled path, so the platform check is off and the function
   authenticates both paths itself:

   ```bash
   supabase functions deploy web-push-send --no-verify-jwt
   ```

   With no VAPID secrets it answers `configured: false` and the app hides the
   switch. Nothing else breaks.

Optional, to make delivery immediate (no laptop, no cron service, no dashboard
webhook — the database does it):

5. **Enable `pg_net`** — Dashboard → **Database → Extensions** → search `pg_net`
   → enable. Migration `00018` creates the dispatch trigger on the next
   migration run; if `pg_net` is absent the migration applies cleanly and
   nothing dispatches, so this step is genuinely optional.

6. **Put the webhook target in Vault** — Dashboard → **Project Settings →
   Vault** → *Add new secret*, twice. Vault is where these belong: the trigger
   reads them at call time, so nothing is baked into the migration and rotating
   the token needs no deploy.

   | Name | Value |
   | --- | --- |
   | `messengerx_push_dispatch_url` | `https://<project-ref>.supabase.co/functions/v1/web-push-send` |
   | `messengerx_push_dispatch_token` | the same value as `WEB_PUSH_SWEEP_TOKEN` |

   Both are required: a URL without a token would only produce a guaranteed 401,
   so an incomplete pair dispatches nothing rather than failing loudly on every
   message.

   **Do not** instead put these in the trigger or a migration — `pg_proc.prosrc`
   is readable by more roles than a secret should be, and this repository keeps
   each secret in exactly one place.

   <details>
   <summary>Alternative without Vault (self-hosted Postgres)</summary>

   A database-local setting works anywhere and is how a local stack points at
   itself. It is read second, so Vault wins when both exist:

   ```sql
   alter database postgres set messengerx.push_dispatch_url =
     'http://host.docker.internal:54321/functions/v1/web-push-send';
   alter database postgres set messengerx.push_dispatch_token = '<sweep token>';
   ```
   </details>

   A **dashboard database webhook** (Database → Webhooks → `web_push_requests`,
   event Insert, HTTP Request, POST, same URL and bearer) also works and needs no
   extension, but it fires at INSERT time and cannot ask the function to wait out
   the fold window, so it delivers on the next sweep instead. `pg_net` is the
   better option because `00018` sends `wait_ms` with the request.

   Without steps 5–6 the feature still works: notices are queued in Postgres and
   **any open app drains the queue on its presence heartbeat**, so the worst case
   is a delay of about a minute rather than a lost notification. With them,
   delivery lands within a few seconds.

### Delivery, in one table

| Configured | Latency | Needs |
| --- | --- | --- |
| Nothing | ~45 s (a heartbeat) | a browser with the app open |
| `pg_net` + Vault (steps 5–6) | a few seconds | nothing of yours running |
| Dashboard webhook | one heartbeat | a webhook in the dashboard |

`00018`'s trigger is `AFTER INSERT` on `web_push_requests`, fires one
asynchronous `net.http_post` per *queued* notice — a burst folds into one row, so
it dispatches once — and runs inside a nested exception block that downgrades any
failure to a warning. **A webhook outage can never fail the message that
triggered it**; the notice simply stays queued for the next sweep. That property
is asserted in `tools/sql-test`.

### How delivery actually works

`send_message` queues at most one folded row per (recipient, chat) in
`web_push_requests` — offline recipients only, never the author, never a muted
or already-read chat, never for traffic the recipient's own Telegram already
delivered. Migration `00018` then dispatches that queue to `web-push-send`
through `pg_net` (steps 5–6), and a sweep calls `web_push_claim`, which leases rows with
`FOR UPDATE SKIP LOCKED` and re-checks immediately before encryption that the
notice is still owed; then `web_push_owed`, then the POST. Reading the chat,
muting it, leaving it, coming back online or switching previews off all cancel a
queued notice and invalidate a live lease. A push service answering 404/410
deletes that subscription, because it is permanently gone; twenty consecutive
failures disables one instead of hammering it forever.

One person may register at most **5 browsers**. Endpoints are unique, so signing
into a different account in the same browser *moves* the subscription to the new
account rather than notifying the old one.

### Verify it, on a real phone

- Sign in on the Vercel origin, open **Telegram → Notifications → Browser
  notifications** and accept the prompt. The row should say "On for this
  browser."
- Close the tab (or lock the phone) and have another account send a message.
- Expect a system notification naming the sender, and a tap that opens that
  chat.

**What this cannot do.** It will not notify someone who never registered a
browser or who blocked the prompt. On an iPhone it works only after **Add to
Home Screen** (iOS 16.4+); a Safari tab cannot subscribe at all, and the switch
says so. It does not appear in the Android or iOS *native* builds — in the app
the Telegram Saved Messages path is still the offline notice. And like every
other claim in this repository, a green CI run is not a device test: the four
steps above are the test.

If a future push service is not on the built-in allowlist (`fcm.googleapis.com`,
`updates.push.services.mozilla.com`, `web.push.apple.com`, `notify.windows.com`
and `*.` subdomains), add it with `WEB_PUSH_ENDPOINT_HOSTS` rather than
loosening the check: the endpoint is user-supplied input, and the allowlist is
what stops it becoming an SSRF primitive.

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
checks; a browser-notification test on a real phone (§5b) if that switch is
advertised; Android signed build/device tests (if advertised); native iOS membership
and device tests (if advertised). The *standalone phone/code identity* option
still needs its own implementation and security review even if Telegram OIDC
is working. Keep that gap visible to users.
