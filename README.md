# MessengerX

A Flutter messenger backed by Supabase Postgres/RLS, with an optional personal
Telegram bridge (TDLib, **not** the Bot API). The same client targets the web,
Android and iOS. This repository is a work-in-progress application, **not a
publicly deployed service**.

## What exists today (25 September 2026)

| Capability | Honest status |
| --- | --- |
| Direct/group MessengerX chats, media, typing, receipts | Implemented; server policies and bridge flows have automated tests. |
| Web client / PWA | Flutter web release **compiles in CI with placeholders**; not published with a real database yet. |
| Google sign-in | Client flow exists; requires hosted Google OAuth and Supabase configuration. No account-age check: Google does not prove account age. |
| Standalone Telegram identity | Gated `custom:telegram` OIDC option (Telegram-app approval). Needs a real BotFather client, hosted provider and live verification before enabling. **Not the requested in-app phone/code identity sign-in.** |
| TDLib phone/code/2FA connection | Exists **after** MessengerX sign-in. Requires a durable worker, a real Telegram API ID/hash and encrypted persistent session storage. |
| Chat with Telegram users | Existing mirrors open in-app; starting a **new** private conversation by an exact public `@username` has an owner-scoped worker queue and simulated tests. No phone-number search/contact import and no real Telegram integration test yet. |
| Notifications | A + C: user's own Telegram Saved Messages for offline folded alerts (mute/read/duplicate suppression), plus local banners while the app is open. No FCM/APNs or promised notice tap-through. |
| Android/iOS binaries | Not distributed or device-tested. iOS web PWA can be installed without an App Store account; native iOS public distribution generally requires a paid developer membership. |
| Hosted database, public site, native worker | **Not provisioned.** SQL/RLS tests are not proof of live security, backup or uptime. |

**$0 constraints:** GitHub Pages (`*.github.io`) can host the static website and
Supabase Free can host the database within quotas; the Free database can pause
when unused. Neither GitHub Pages, Vercel, short-lived functions nor a sleeping
Render instance is a durable TDLib user-session worker. We do not have a verified
$0 always-on host with persistent private session storage. The app's personal
Telegram chat and offline notice features must not be advertised as live until
that worker has been securely provisioned and tested. No Oracle signup or
always-on personal computer is assumed.

## Map of the repository

```text
apps/mobile_app/            Flutter UI, web scaffold, Android/iOS project sources when reviewed
supabase/migrations/        SQL schema, RLS, RPCs, storage policies and queues
supabase/functions/         Deno edge functions: link, send, ingest, legacy access status
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

The [CI workflow](.github/workflows/ci.yml) runs the Flutter tests and a
placeholder-config web release build. A green CI run cannot verify real OAuth,
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

See [docs/runbook.md](docs/runbook.md) for precise provisioning and verification
steps, [docs/telegram-sign-in.md](docs/telegram-sign-in.md) for the independent
Telegram OIDC setup, and [docs/architecture.md](docs/architecture.md) for trust
boundaries. The GitHub Pages publish job is intentionally **opt-in** and cannot
run until a hosted project, OAuth providers and a durable worker have been
validated. For the explicit phone/code **identity** requirement (not just TDLib
linking), a secure Supabase session issuance/recovery design still needs to be
implemented. This README does not treat OIDC approval as a silent substitute.

## License

MIT.
