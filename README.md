# Massanger

A private messenger with a real Telegram body: your chats live in Postgres behind
row-level security, and a TDLib userbot keeps your personal Telegram account mirrored in
both directions — inbound messages and media into the same `messages` table you already
read, outbound messages from Massanger into Telegram as if you had typed them there.

Flutter + Supabase + a long-lived Node worker. No Telegram Bot API: a bot cannot read
your history or post as you, and "two-way sync with my account" is the whole feature.

```
apps/mobile_app            Flutter client (flutter_bloc, go_router, get_it)
supabase/migrations        00001…00011: model, RLS, RPCs, triggers, realtime, storage
supabase/functions         Deno edge functions: account-age gate, link, send, ingest
services/telegram_bridge   TDLib worker: sessions, outbox lease loop, ingest, presence
tools                        PGlite suites + typecheck configs
docs                       runbook.md (operations) · architecture.md (contracts)
infra                      docker-compose for the worker + TDLib sidecar
```

## Five-minute start

```bash
make bootstrap          # npm ci + flutter pub get + local .env files
supabase start          # needs Docker: Postgres, PostgREST, Storage, Realtime, Studio
make db-reset           # apply 00001…00011 + seed.sql
npm run check           # 59 schema + 8 seed + 87 bridge assertions, both typechecks
make bridge             # the sync worker (BRIDGE_TRANSPORT=memory: no Telegram needed)
```

Then fill `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `.massanger/app.json` with the values
`supabase start` prints, and run the app:

```bash
make app                # flutter run --dart-define-from-file=../../.massanger/app.json
```

`make help` lists every task. [docs/runbook.md](docs/runbook.md) covers what cannot be
created by a script: the Google Cloud project behind the account-age gate, a real
Telegram API credential, and deploying the worker.

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
  directions (reading in Telegram clears the Massanger badge; reading in Massanger sends
  `viewMessages`).
- Sign-in with Google, gated on the account being older than 366 days — checked server
  side against Gmail, with Drive as fallback, and rendered by the app as a state it
  cannot edit.
- A Telegram panel that links the account by QR or phone+code, chooses what mirrors
  (`sync_direction` per account and per chat), and unlinks cleanly. Credentials are
  sealed on the way in and never stored in plaintext.

## Verification status

Everything that can be checked without a Telegram account or a phone is checked in CI
(`.github/workflows/ci.yml`):

| Command | Result here | What it proves |
| --- | --- | --- |
| `npm run test:sql` | 59/59 | RLS matrix, RPC semantics, trigger invariants — on real Postgres (PGlite), no Docker |
| `npm run test:seed` | 8/8 | `seed.sql` applies on top of the migrations and its fixtures hold |
| `npm run test:bridge` | 87/87 | auth state machine, outbox lease + `FLOOD_WAIT` parking, media prep, ingest, presence, admin HTTP |
| `npm run typecheck` | clean | all four Deno functions and the worker, under `strict` |
| `make app` / `flutter test` | needs the SDK | the analyzer and the app's own tests are the gate |

The Flutter sources in `apps/mobile_app/` are written against the packages pinned in
`pubspec.yaml` but are only executed by `flutter analyze` / `flutter test` on a machine
with the Flutter SDK installed; run those first after cloning
(`flutter --version` should report 3.24 or newer).

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
