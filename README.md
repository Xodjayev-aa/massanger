# MessengerX

A private messenger with a real Telegram body: your chats live in Postgres behind
row-level security, and a TDLib userbot keeps your personal Telegram account mirrored in
both directions — inbound messages and media into the same `messages` table you already
read, outbound messages from MessengerX into Telegram as if you had typed them there.

Flutter + Supabase + a long-lived Node worker. No Telegram Bot API: a bot cannot read
your history or post as you, and "two-way sync with my account" is the whole feature.

```
apps/mobile_app            Flutter client (flutter_bloc, go_router, get_it)
supabase/migrations        00001…00012: model, RLS, RPCs, triggers, realtime, notices
supabase/functions         Deno edge functions: account-age gate, link, send, ingest
services/telegram_bridge   TDLib worker: sessions, outbox + notice leases, ingest
tools                        PGlite suites + typecheck configs
docs                       runbook.md (operations) · architecture.md (contracts)
infra                      Oracle systemd unit + optional self-contained bridge Compose
```

## Five-minute start

```bash
make bootstrap          # npm ci + flutter pub get + local .env files
supabase start          # needs Docker: Postgres, PostgREST, Storage, Realtime, Studio
make db-reset           # apply 00001…00012 + seed.sql
npm run check           # 79 schema + 8 seed + 102 bridge assertions, both typechecks
make bridge             # the sync worker (BRIDGE_TRANSPORT=memory: no Telegram needed)
```

Then fill `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `.messengerx/app.json` with the values
`supabase start` prints, and run the app:

```bash
make app                # flutter run --dart-define-from-file=../../.messengerx/app.json
```

`make help` lists every task. [docs/runbook.md](docs/runbook.md) covers what cannot be
created by a script: the Google Cloud project behind the account-age gate, a real
Telegram API credential, and deploying the worker on an **Oracle Cloud Always Free
ARM VM** (§4.1). The worker is not hosted by this repository; you must provision
and link the external accounts yourself. A free subdomain is enough for a
web-compatible prototype (the current Flutter media paths need web adaptation);
the worker needs no domain or public inbound port.

## What the app does

- Threads over `chat_summaries` / `chat_feed`, with unread counts, presence and full-text
  search (`chat_summaries(p_query)` / `search_messages`), all through RPCs — the client
  never queries a table directly.
- Optimistic sends that reconcile on `client_message_id`: the bubble you see while the
  network is slow is replaced in place by the real row, so nothing jumps or duplicates.
- Images (picked, uploaded to `images/<chat>/`, viewed in a swipeable gallery) and voice
  notes (recorded with a live level meter, a 64-bar waveform stored with the message,
  one shared audio player, tap-the-waveform to seek).
- Reply, delete-for-everyone, retry-after-failure, read receipts that travel in both
  directions (reading in Telegram clears the MessengerX badge; reading in MessengerX sends
  `viewMessages`).
- Sign-in with Google, gated on the account being older than 366 days — checked server
  side against Gmail, with Drive as fallback, and rendered by the app as a state it
  cannot edit.
- A Telegram panel that links the account by phone+code (QR is not supported by
  this worker), chooses what mirrors (`sync_direction` per account and per chat),
  and unlinks cleanly. Credentials are sealed on the way in and never stored in
  plaintext.
- Offline notices via the recipient's **own Telegram Saved Messages**, plus local
  foreground banners: 90-second away rule, 3-second burst folding, mute/read
  cancellation, preview privacy, and suppression if the same Telegram chat already
  notified them. The Telegram screen has two switches; chat headers can mute for
  8 hours. No APNs/FCM, device tokens, paid notification service or deep-link tap.
  **Saved Messages text delivery is testable; an OS buzz for self-sent messages
  depends on the Telegram client and must be checked on real phones** (§5.2).

## Verification status

Everything that can be checked without a Telegram account or a phone is checked in CI
(`.github/workflows/ci.yml`):

| Command | Result here | What it proves |
| --- | --- | --- |
| `npm run test:sql` | 79/79 | RLS matrix, message triggers, offline notice leases / mute / privacy — on Postgres (PGlite), no Docker |
| `npm run test:seed` | 8/8 | `seed.sql` applies on top of the migrations and its fixtures hold |
| `npm run test:bridge` | 102/102 | auth, outbox, notice sends + self-chat suppression, flood parking, media, ingest, admin HTTP |
| `npm run typecheck` | clean | all four Deno functions and the worker, under `strict` |
| `bash tools/verify-client.sh` | requires Flutter SDK; not run here | `pub get`, strict analyzer, then tests; optional `--fix` applies Dart fixes/format |

The Flutter sources in `apps/mobile_app/` need the Flutter SDK for `flutter analyze`
and `flutter test` (including the new notification preference test). This sandbox has
no Flutter SDK, so their analyzer/widget status is **not yet verified** here; run
both on a machine or CI with Flutter ≥3.24 before distributing a build. Run
`bash tools/verify-client.sh` there (`--fix` only when you choose to modify Dart
sources). For the Oracle VM use the checked-in `infra/messengerx-bridge.service`
and the installation block in [runbook §4.1](docs/runbook.md).
A real Telegram account and iOS/Android device are needed for the notice-buzz
smoke test; a Saved Messages row alone is not proof of an iOS lock-screen alert.

## Rules of the house

- Never edit an applied migration; add the next number, and remember that a new function
  owns its own `grant`s and any streamed table needs `alter publication …`.
- `docs/runbook.md §8` is the schema checklist, `docs/architecture.md` the contracts.
- Media has one shape (`app.validate_message_media`) and one location rule per bucket;
  the two must stay in sync or assets 403 while validating fine.
- Correlate by id — `client_message_id`, `dedupe_key`, `sending_id`,
  `(chat_id, source, tg_message_id)`. Never by message text.

## Licence

MIT.
