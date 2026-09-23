# MessengerX — Flutter client

The app is a thin, opinionated layer over the RPCs in `supabase/migrations`: it renders
state the server decided, keeps one realtime subscription per open screen, and never
holds a Telegram credential.

```
lib/
  main.dart              bootstrap: env validation, DI, bloc observer, run
  core/
    env.dart             AppEnv — compile-time --dart-define values, fails loudly
    errors.dart          AppException.wrap: PostgREST/Auth/Storage/Socket → one type + copy
    formatting.dart      timestamps, durations, day headers (one rule, everywhere)
    waveform.dart        dBFS → 64 bars, and the sanitize() that guards the DB contract
  data/
    models.dart          row → immutable models (parseTimestamp / asInt / asBool)
    chat_repository.dart     chat_summaries, chat_feed, send_message, receipts, search
    account_repository.dart  profiles, update_profile, eligibility_status, avatar upload
    telegram_repository.dart telegram_link_state, set_preferences, set_chat_sync, unlink
    voice_service.dart       record + one shared player + amplitude → waveform
  app/
    theme.dart  di.dart  router.dart  app.dart
  features/
    auth/        auth_bloc, sign_in_page, gate_page
    chats/       chats_bloc, chats_page, new_chat_page, search_page, widgets
    chat/        chat_bloc, chat_page, composer, message_bubble, photo_viewer
    telegram/    telegram_cubit, link_cubit, telegram_page, link_page
    profile/     profile_cubit, profile_page
test/            contract tests: media jsonb shape, timestamps, waveform, AppEnv
env/app.example.json  template for the --dart-define file
```

## First run

```bash
cd apps/mobile_app
flutter create .                 # generates ios/, android/, web/ around lib/ (once)
flutter pub get
```

`flutter create .` is needed because the platform folders are generated artifacts — the
repo tracks `lib/`, `test/`, `pubspec.yaml`, `analysis_options.yaml` and this README.
Use `--org com.messengerx --project-name messengerx_app` if you want the generated bundle
ids to match the ones Supabase and Google are configured for; the deep-link callback
scheme below assumes `com.messengerx.app`.

Then give the app its endpoint (values come from `supabase start` or your hosted
project — see [../../docs/runbook.md](../../docs/runbook.md) §2):

```bash
cp env/app.example.json ../../.messengerx/app.json
# edit .messengerx/app.json: SUPABASE_URL, SUPABASE_ANON_KEY
flutter run --dart-define-from-file=../../.messengerx/app.json
```

`make app` from the repo root does exactly that. `AppEnv.validate()` throws at start-up
if a build has no URL — an app that silently points at the wrong project is worse than a
build that fails.

### Configuration

| `--dart-define` key | Meaning | Required |
| --- | --- | --- |
| `SUPABASE_URL` | API origin; also used to derive the Realtime `wss://…` URL | yes |
| `SUPABASE_ANON_KEY` | the public anon key (RLS enforces, so this is safe to compile in) | yes |
| `FUNCTION_BASE_URL` | only if edge functions are served from another host | no |
| `MIN_ACCOUNT_AGE_DAYS` | copy only; the server decides | no (366) |
| `DISABLE_REALTIME` | `true` → poll on focus instead of subscribing; for debugging | no |

Nothing secret is compiled in: the service-role key never reaches the client, and
Telegram credentials go to `functions/v1/telegram-link` over TLS and straight into a
sealed envelope the app cannot read back.

## Platform permissions

Both are needed for the features in `features/chat/composer.dart`, and both are the
reason a first run on a device differs from a first run on the simulator.

**iOS — `ios/Runner/Info.plist`:**

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MessengerX records a voice note when you hold the microphone button.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Pick photos to send in a chat.</string>
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLSchemes</key>
  <array><string>com.messengerx.app</string></array>
</dict></array>
```

The URL scheme is what lets `signInWithOAuth` return from the browser; it must also be
listed in Supabase → Auth → URL Configuration → Additional redirect URLs (it is in
`supabase/config.toml` for local).

**Android — `android/app/src/main/AndroidManifest.xml`:**

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<!-- inside <application> -->
<activity android:name=".MainActivity" android:exported="true"
          android:launchMode="singleTask" android:configChanges="…">
  <intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="com.messengerx.app" />
  </intent-filter>
</activity>
```

and in `android/app/build.gradle` set `minSdkVersion 23` (`record` 5.x requires it). No
`google-services.json` is involved: sign-in is Supabase's generic OAuth flow through
`url_launcher`, not the native Google Sign-In SDK, which is also why the *web* Google
client id is the one the server validates.

## Behaviour worth knowing before you change it

- **Optimistic sends reconcile on `client_message_id`.** The placeholder bubble is keyed
  by the client uuid; the realtime `messages` insert replaces it *in place* (same index)
  instead of appending, so the list never jumps. Never match on body text — an edit or a
  Telegram-side truncation would duplicate the message.
- **Paging** is `chat_feed(p_chat_id, p_before_id)` on an infinite scroll, and the list is
  reversed, so "load older" fires at `maxScrollExtent`. Grouping (same sender, < 120 s
  apart) is a render-time decision, not stored state.
- **Typing** notifies once per 2.5 s of activity, re-asserts every 5 s, and cancels on
  focus loss and on `close()` — a stale "typing…" row is a bug the server cannot fix,
  because `set_typing(p_on: false)` deletes it.
- **Receipts** are only sent for other people's messages while the chat is focused, via
  `mark_messages_delivered`; read-marking is `mark_chat_read` on dispose/open.
- **Voice notes** are recorded with `record` 5.x (`amp` stream → `Waveform.fromDbfs`),
  uploaded as `voice-notes/<chat>/<uuid>.wav`, and played through one shared
  `just_audio` player — creating a player per bubble is how you get stuck audio focus.
  A failed upload leaves the bubble with a retry button that resends the same media map.
- **Avatars** are public (`getPublicUrl`), everything else needs a signed URL, so
  `ChatRepository.urlFor(media)` is the only place that knows which is which.
- **The router is built once.** Navigation redirects for `access_state` come from a
  `Listenable` refresh, not from rebuilding the GoRouter in a `BlocBuilder` — rebuilding
  the router throws away navigation state mid-compose.
- **No local database.** Cached state lives in the blocs for the session; an offline
  client shows what it has and disables sends. If offline history becomes a requirement,
  do it as a repository implementation behind `ChatRepository`, not as widget-level
  caching.

## Checks

```bash
flutter analyze            # strict-casts/inference/raw-types; avoid_print and
                           # unawaited_futures are errors (analysis_options.yaml)
flutter test               # the contract tests in test/ — no device, no network
dart format lib test       # the house style; `make fmt` from the root does both
```

`test/media_contract_test.dart` is the one to read before touching `models.dart`: it
spells out what `send_message(p_media: …)` must contain, key for key, because a renamed
key is a `22023` from Postgres and a broken bubble in the UI with nothing in between to
catch it.

Dependencies are deliberately narrow: `supabase_flutter`, `flutter_bloc`, `equatable`,
`go_router`, `get_it`, `record`, `just_audio`, `image_picker`, `permission_handler`,
`path_provider`, `cached_network_image`, `photo_view`, `qr_flutter`, `intl`, `uuid`.
No secure-storage package on purpose: nothing worth a keychain is kept on the client
(the Supabase session uses its own platform storage, and Telegram credentials never
touch the app's storage).
