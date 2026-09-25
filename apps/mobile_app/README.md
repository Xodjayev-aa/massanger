# MessengerX Flutter client

One Flutter source tree for the web PWA and planned Android/iOS builds. The web
scaffold is tracked under `web/`; native `android/` and `ios/` projects are **not
tracked or distributed yet**. CI generates native scaffolds temporarily for
analysis but has not produced a reviewed, signed, device-tested app. This code
uses Supabase Auth/Postgres/RLS, Storage and Edge Functions; a separate durable
TDLib worker is needed for Telegram chat. See the [launch runbook](../../docs/runbook.md)
for what must be provisioned before a public website or native app works.

## Development

Use Flutter 3.24.5 (the CI version). From the repository root:

```bash
npm ci && npm run check             # database, functions and worker simulator
make env                            # create ignored local config templates
# Configure local Supabase; see docs/runbook.md for Docker/CLI steps.
cd apps/mobile_app
flutter pub get
flutter run -d chrome --web-port 5050 \
  --dart-define-from-file=../../.messengerx/app.json
```

For a production website, compile against a **real** hosted Supabase project,
not the placeholders used by CI. The workflow's opt-in Pages job builds with
`--base-href=/massanger/`. Keep browser redirects on the public website origin,
not localhost; GitHub Pages must have a matching Supabase redirect allowlist.

| `--dart-define` | Meaning |
| --- | --- |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Hosted API HTTPS URL and **public** anon/publishable key; both required. Never compile the service-role key into a client. |
| `WEB_REDIRECT_URL` | Full public website URL **including base path** for OAuth return (e.g. `https://xodjayev-aa.github.io/massanger/`). |
| `FUNCTION_BASE_URL` | Only when functions live on another origin. |
| `TELEGRAM_OIDC_ENABLED` | Set `true` only after the hosted `custom:telegram` provider has passed its sign-in smoke test. This is Telegram-app OIDC approval, **not** in-app phone/code sign-in. |
| `DISABLE_REALTIME` | Set `true` only for debugging/focus polling. |

Google sign-in (minimal profile scope) and the gated Telegram OIDC button are
**identity** options. Neither creates a TDLib chat session. After signing in,
users must connect their Telegram account through the phone → code → optional
2FA wizard; no phone/code-only MessengerX *identity login* has been implemented.
The app does not prove the age of a Google account. Do not silently merge
Google and Telegram identities; linking identities needs its own secure design.

## Native projects: not ready to distribute

If generating locally, use the same identity as CI so files can be reviewed:

```bash
flutter create --platforms=android,ios --org com.messengerx \
  --project-name messengerx_app .
```

Before distributing, review and **track** the generated platform files, align
the Android application ID and iOS bundle ID with your chosen identifiers, and
wire these permissions/callbacks in the platform projects:

- Android: `INTERNET`, `RECORD_AUDIO`, a `VIEW`/`BROWSABLE` intent filter for
  `com.messengerx.app://login-callback`, and the recording plugin's required
  minimum SDK. Test the callback on an actual device and use a protected,
  durable signing key for updates.
- iOS: `NSMicrophoneUsageDescription`, `NSPhotoLibraryUsageDescription`, and
  `CFBundleURLTypes` for `com.messengerx.app`. Compile and test on a Mac with
  Xcode. Native public iOS distribution generally requires a paid Apple
  Developer Program membership; a web PWA is the $0 install option.

The native scheme must also be listed in Supabase Auth's production redirect
allowlist **only after** those platform handlers exist. A generated scaffold is
not proof that callbacks, photo/voice permissions or signed releases work.

## Checks and behavior

```bash
flutter analyze --no-fatal-infos
flutter test --reporter expanded
flutter build web --release --dart-define-from-file=../../.messengerx/app.json
```

`bash tools/verify-client.sh` runs the same analyzer/tests and a **placeholder**
web build from the repository root; that build cannot be used to sign in.

Sends reconcile on `client_message_id`, media JSON shape is validated by the
backend, and private media use signed Storage URLs. The client keeps only
session-scoped cached state: offline sends are disabled, and an installed PWA
is not an offline chat-history app. Notification path A + C is Saved Messages
on the user's own Telegram session when offline (requires the worker), plus
local in-app banners while running. It is **not** FCM/APNs, a guaranteed OS
push or an implemented notification deep link. Live device verification is
still required.
