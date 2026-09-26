# MessengerX

A Flutter messenger backed by Supabase Postgres/RLS, with an optional personal
Telegram bridge (TDLib, **not** the Bot API). The same client targets the web,
Android and iOS. This repository is a work-in-progress application, **not a
publicly deployed service**.

## What exists today (25 September 2026)

| Capability | Honest status |
| --- | --- |
| Direct/group MessengerX chats, media, typing, receipts | Implemented; server policies and bridge flows have automated tests. |
| Web client / PWA | Flutter web release compiles in CI at site root `/`. Intended Vercel Hobby URL is `https://messengerx-uz.vercel.app` — **not serving a deployment** (`DEPLOYMENT_NOT_FOUND` on 25 September 2026). GitHub Pages `/massanger/` is retired (404). |
| Google sign-in | Client flow exists; requires hosted Google OAuth and Supabase configuration. No account-age check: Google does not prove account age. |
| Standalone Telegram identity | Gated `custom:telegram` OIDC option (Telegram-app approval). Needs a real BotFather client, hosted provider and live verification before enabling. **Not the requested in-app phone/code identity sign-in.** |
| TDLib phone/code/2FA connection | Exists **after** MessengerX sign-in. Requires a durable worker, a real Telegram API ID/hash and encrypted persistent session storage. |
| Chat with Telegram users | Existing mirrors open in-app; starting a **new** private conversation by an exact public `@username` has an owner-scoped worker queue and simulated tests. No phone-number search/contact import and no real Telegram integration test yet. |
| Notifications | Three paths, none of them FCM/APNs: **browser push** (`00017`, needs no worker — the browser's push service delivers, a service worker draws the notification, and any open app drains the queue) with tap-through into the chat; the user's own Telegram Saved Messages for offline folded alerts (mute/read/duplicate suppression), which needs the TDLib worker; and local banners while the app is open. Browser push needs VAPID secrets set (§5b of the runbook) and a real device test before it is claimed as working. |
| Android/iOS binaries | Native project sources, OAuth callbacks, permissions and icons are tracked; CI checks a placeholder-config Android debug build. No signed release or device test. iOS PWA is the $0 install path. |
| Hosted database, public site, native worker | **Not provisioned.** SQL/RLS tests are not proof of live security, backup or uptime. |

**$0 constraints:** Vercel Hobby can host the static website at
`https://messengerx-uz.vercel.app` (see [docs/vercel.md](docs/vercel.md)), and
Supabase Free can host the database within quotas. The Free database can pause
when unused. Browser notifications (`00017`) are the one alert path with no
always-on requirement at all: they need the hosted database, a deployed
`web-push` function and a VAPID key pair, and nothing else. The old GitHub Pages URL returns 404 and is not the deployment
path. Vercel is website hosting only. Neither Vercel, short-lived functions nor
a sleeping free instance is a durable TDLib user-session worker. We do not have
a verified $0 always-on host with persistent private session storage. Chatting
with real Telegram users and offline Saved Messages notices must not be
advertised as live until that worker has been securely provisioned and tested.
Browser notifications do not wait on that worker, but they are not proven either
until the device test in the runbook passes.
No Oracle signup or always-on personal computer is assumed. There is no signed
public Android installer. The $0 iPhone option is the PWA (Add to Home Screen),
not an App Store app. Standalone in-app phone/code identity sign-in is not
implemented.

## Map of the repository

```text
apps/mobile_app/            Flutter UI, web PWA and reviewed Android/iOS platform source
apps/mobile_app/web/push/   Web Push client + service worker (the $0 no-worker alerts)
supabase/migrations/        SQL schema, RLS, RPCs, storage policies and queues
supabase/functions/         Deno edge functions: link, send, ingest, push, legacy access status
services/telegram_bridge/  TDLib worker, simulated transport and tests
infra/                     Optional worker process/container examples (not a host)
tools/sql-test/             PGlite migration, security and queue contract tests
docs/runbook.md             Local checks, deployment checklist and launch blockers
docs/telegram-sign-in.md    Google/Telegram OIDC versus TDLib phone/code
```

## Verify the code

```bash
npm ci
npm run check           # SQL migrations/RLS + seed + edge config + bridge simulator + TS types
bash tools/verify-client.sh   # requires a local Flutter SDK; analyze, test, web build
```

The [CI workflow](.github/workflows/ci.yml) runs Flutter tests, a
placeholder-config web release build and an Android **debug** compile check.
A green CI run cannot verify real OAuth,
Supabase RLS on hosted Postgres, Telegram's MTProto servers, Android/iOS device
permissions or a running worker.

For local Supabase development use `make env`, `make db-start`, `make db-reset`,
then configure `.messengerx/app.json` and run `make app` with the Flutter SDK.
Local Supabase needs Docker. `make bridge` defaults to the **simulator**; the
real `koffi` transport additionally needs a pinned TDLib shared library and
operator-owned Telegram API credentials. Never put a service-role key, bridge
token, BotFather secret, TDLib session or Google client secret in Flutter, a
web build, repository variables or a Git commit. A Supabase publishable/anon
key is public by design; RLS must still be tested.

## Path to a public launch

See [docs/vercel.md](docs/vercel.md) for the Vercel Hobby project name,
dashboard clicks, and the split between Google's JavaScript origin and
Supabase's `/auth/v1/callback`. See [docs/runbook.md](docs/runbook.md) for
migrations, RLS and backups, [docs/telegram-sign-in.md](docs/telegram-sign-in.md)
for the independent Telegram OIDC setup, and
[docs/architecture.md](docs/architecture.md) for trust boundaries. Connecting
Vercel does not apply database migrations and does not start a Telegram worker.
For the explicit phone/code **identity** requirement (not just TDLib linking),
a secure Supabase session issuance/recovery design still needs to be
implemented. This README does not treat OIDC approval as a silent substitute.

## License

MIT.
