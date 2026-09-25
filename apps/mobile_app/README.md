# MessengerX Flutter client

One Flutter source tree for the web PWA and planned Android/iOS builds. Web,
Android and iOS platform source is tracked. The native projects include an OAuth
callback scheme, microphone/photo permissions and MessengerX icons, but there
is **no signed, device-tested, publicly distributed native app**. CI builds
Android with placeholder config for a compile check, not a release. This code
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

The tracked Android project uses `applicationId`/namespace `com.messengerx.app`,
API 23+, `INTERNET` + `RECORD_AUDIO`, and an exact `VIEW`/`BROWSABLE` OAuth
callback for `com.messengerx.app://login-callback`. The tracked iOS project
uses bundle ID `com.messengerx.app`, microphone/photo usage descriptions and
`CFBundleURLTypes`. Both leave Flutter's built-in route deep-link handler off so
Supabase Flutter can consume OAuth callbacks. **Do not run `flutter create .`
over the reviewed files** or blindly overwrite these settings.

Before distribution, test the OAuth callback, voice and photo permissions, and
real-config messages on physical devices. The Android *release* configuration
is intentionally **unsigned** rather than debug-signed; the operator must
store a durable release signing key privately, configure Gradle signing, then
build and test a signed APK/AAB. CI's placeholder Android **debug** build is
not a production binary. For iOS, compile and test with Xcode on a Mac; public
native distribution generally needs paid Apple Developer membership. For a $0
iOS install, use the HTTPS PWA instead.

Allow `com.messengerx.app://login-callback` in hosted Supabase Auth only for
native builds with this scheme that you have actually tested. The app ID may
need to change if it conflicts with an existing publisher: update both native
projects, the callback scheme and Auth allowlist together. Platform source is
not proof that device-level behavior or signing works.

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
