# MessengerX runbook

Operational truth for this repository: how to get it running, what has to be
provisioned outside the repo, and what to do when Telegram stops syncing.

Numbers quoted here are asserted by the test suites, not by memory: 59 schema
behaviours (`tools/sql-test/run.mjs`), 8 seed checks (`tools/sql-test/seed-check.mjs`),
87 bridge behaviours (`services/telegram_bridge/test/*.test.ts`).

---

## 0. Three questions, answered up front

**Do I need Docker?** Only for a running database. `supabase start` /
`supabase db reset` / `supabase functions serve` are Docker-based, and that local
stack is the only place the app gets Realtime, Storage and the PostgREST endpoints.
Everything else works without a daemon:

| Command | Needs Docker |
| --- | --- |
| `make test` (`test:sql`, `test:seed`, `test:bridge`) | no — PGlite + the in-process transport |
| `npm run check` (tests + both `tsc` typechecks) | no |
| `make bridge` with `BRIDGE_TRANSPORT=memory` | no |
| `supabase start`, `db reset`, `functions serve`, Studio | **yes** |
| `flutter run` against the local stack | **yes** (it needs the stack) |
| `flutter test` | no |

So a reviewer can verify the schema and the sync worker on a laptop with Node alone;
you need Docker (or a hosted project) the moment you want the app to talk to
something.

**Which Google OAuth credentials?** Three OAuth clients, all in the *same* Google
Cloud project, and one Google Cloud project is enough for the whole feature:

1. **Web** client — used twice: it is the client Supabase Auth redirects to
   (`supabase/.env` → `GOOGLE_OAUTH_CLIENT_ID`, read by `config.toml`), and it is the
   client whose *secret* lets `account-age-gate` exchange an access token for
   `userinfo`/`tokeninfo` (`GOOGLE_WEB_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` in
   `supabase/functions/.env.local`).
2. **iOS** client (`GOOGLE_IOS_CLIENT_ID`) — its bundle id must be
   `com.messengerx.app`, and it must list the web client as an *embedded* client or
   `sign-in-with-google` on iOS will mint an ID token our server refuses.
3. **Android** client (`GOOGLE_ANDROID_CLIENT_ID`) — needs the debug *and* release
   SHA-1 fingerprints; a missing fingerprint is the single most common cause of
   `ApiException: 10` on a fresh clone.

Scopes requested: `openid email profile` plus `https://www.googleapis.com/auth/gmail.readonly`
(primary age signal, Gmail API) and `https://www.googleapis.com/auth/drive.metadata.readonly`
(fallback, Drive API). Both must be **enabled** in the Google Cloud project, and while
the app is unverified the consent screen shows a warning and refresh tokens last 7 days —
that only affects repeat verifications, not the first one (see §3).

**Which transport should be tested?** TDLib, always — that is the product. The bridge
exposes three interchangeable transports and one of them is a simulator:

| `BRIDGE_TRANSPORT` | What it is | Use it for |
| --- | --- | --- |
| `memory` | In-process TDLib simulator. Real outbox loop, real lease/FLOOD_WAIT handling, fake Telegram. | unit/integration tests, `make bridge` on a laptop, demos |
| `koffi` | `libtdjson` loaded into the Node process | production default |
| `td_ws` | A websocket TDLib sidecar (`TD_WS_URL`) | when you want TDLib upgraded independently of the worker image |

The suite (`npm run test:bridge`) exercises the protocol **contract** against
`memory`, which is the only honest way to test `updateAuthorizationState`,
`sending_id` echo correlation and `FLOOD_WAIT_n` parking without talking to
Telegram's servers. `koffi`/`td_ws` are then verified by the same code path against a
real account — §5 ends with that checklist. GramJS is deliberately **not** an adapter:
it cannot correlate an outbound message with its `sending_id`, and its own
authorization state machine cannot be paused to let the user type a code, which is the
whole shape of the link flow.

---

## 1. What the system is made of

```
Flutter app ──PostgREST/RPC──▶ Supabase (Postgres + Storage + Realtime)
                                   ▲        │
                                   │        ▼ (realtime: messages/chat_typing)
                                   │     bridge workers (1 per N users)
   app ──functions/v1/telegram-link──┤        │ TDLib (getAuthorizationState,
   app ──functions/v1/telegram-send──┤        │ sendMessage, viewMessages, …)
   app ──functions/v1/account-age-gate┘        ▼
                                        telegram_inbox_events ──▶ ingest RPC
```

Four edge functions (`account-age-gate`, `telegram-link`, `telegram-send`,
`telegram-ingest`), eleven migrations, one long-lived Node worker per shard, and the
app. The app never holds a Telegram credential: credentials travel inside a
per-request AES-GCM envelope that only the bridge can open, and the envelope never
lands in a table (`telegram_link_requests.payload` stores ciphertext, and
`guard_link_request_update` forbids reading it back).

---

## 2. Local development, from a clean machine

You need: Node ≥ 20.11 (22 recommended), Flutter ≥ 3.24 with the Dart SDK it ships,
the Supabase CLI ≥ 2.0, Docker, and `make`.

```bash
git clone <this repo> && cd messengerx
make bootstrap        # npm ci + flutter pub get + creates the .env files
```

`make bootstrap` never overwrites an existing secret file. It creates:

- `supabase/.env` — project ref, DB password, and the `GOOGLE_OAUTH_*` pair that
  `config.toml` interpolates for Auth.
- `supabase/functions/.env.local` — the four functions' runtime environment.
- `services/telegram_bridge/.env` — the worker's environment.
- `.messengerx/app.json` — the `--dart-define` values the app builds with.

Start the stack:

```bash
supabase start
```

Expected, in order: `[+] Creating custom roles`, `[+] Starting Postgres`,
`[+] Starting API gateway`, then a table of URLs. Write down three of them:

```
API URL     http://127.0.0.1:54321     → SUPABASE_URL (app + functions)
DB URL      postgresql://postgres:postgres@127.0.0.1:54322/postgres
Studio      http://127.0.0.1:54323
```

`supabase start` prints an `anon key` and a `service_role key`. Fill them in:

| File | Key | Value |
| --- | --- | --- |
| `supabase/functions/.env.local` | `SUPABASE_URL` | keep `http://127.0.0.1:54321` |
| | `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` | from the CLI output |
| | `SUPABASE_JWT_SECRET` | the CLI's `JWT secret` (default matches `config.toml`) |
| `services/telegram_bridge/.env` | `SUPABASE_URL`, both keys | same values |
| | `SEAL_KEY`, `BRIDGE_HMAC_SECRET`, `BRIDGE_TOKEN` | must equal the function's values |
| | `BRIDGE_BASE_URL` | `http://host.docker.internal:8787` (a function in Docker cannot reach `localhost`) |
| `.messengerx/app.json` | `SUPABASE_URL`, `SUPABASE_ANON_KEY` | API URL + anon key |

Migrations and `seed.sql` are applied by `supabase start` (and by
`supabase db reset`, which is the check CI runs against PGlite):

```bash
make db-reset        # replay 00001..00011 then seed.sql
npm run check        # 59 SQL + 8 seed + 87 bridge assertions + both typechecks
make bridge          # BRIDGE_TRANSPORT=memory, tails the poll loop
(cd apps/mobile_app && flutter run)
```

Three things to know about this local setup:

- **Storage buckets are created by migration 00008** (`avatars` 5 MiB,
  `images` 20 MiB, `voice-notes` 10 MiB) with their policies, so a reset gives you a
  working media pipeline. `avatars` is public-read (the app uses `getPublicUrl` for
  it); the other two are chat-scoped and can only be read through signed URLs.
- **Realtime works out of the box**: `messages`, `chats` and `chat_typing` are added to
  the `supabase_realtime` publication in 00008, and RLS filters the stream per member.
  If a device stops receiving messages after a network change, the app resubscribes on
  resume — you do not need a reconnect button.
- **Phone OTP is intentionally disabled** (`config.toml` → `[auth.sms]`). Sign-in is
  Google-only; the phone number only exists as the identity being linked to Telegram.
  To see a "delivered" code locally, read `supabase`'s Inbucket-free equivalent in the
  `auth` logs, or run `select * from {{ auth.users }}` in Studio.

### Running without Docker at all

`npm run check` needs nothing but Node. To use the app you need a PostgREST/Storage/
Realtime endpoint, i.e. a hosted Supabase project (§4) or Docker. There is no supported
"app without a database" mode.

---

## 3. Google credentials and the account-age gate

### 3.1 Provisioning

1. Google Cloud console → new project, e.g. `messengerx-prod`.
2. **OAuth consent screen**: External, add the scopes
   `gmail.readonly`, `drive.metadata.readonly`, plus the OpenID ones. Publish
   "Testing" while developing (≤ 100 test users, 7-day refresh tokens) and
   "In production" once the verification for `gmail.readonly` clears.
3. **Credentials → Create OAuth client ID**, three times: Web, iOS, Android (§0).
   Authorized origins: `http://127.0.0.1:54321`, `https://<project-ref>.supabase.co`.
   Authorized redirect URI: `https://<project-ref>.supabase.co/auth/v1/callback`
   and `http://127.0.0.1:54321/auth/v1/callback`.
4. **Enable APIs**: People API is not needed; enable **Gmail API** and **Google Drive
   API**. The gate reads only the account's creation date, never message content:
   Gmail `users.getProfile` (`msgTotal`/`totalBytes` are not read) and Drive
   `about.get`'s creation time, so the consent text can stay short.
5. In Supabase: **Auth → Providers → Google**, paste the *web* client id/secret.
   Set **Auth → URL Configuration** → Site URL `io.messengerx.app://login-callback`
   handling via `additional_redirect_urls` (already in `config.toml` for local).

### 3.2 What the gate actually decides

`supabase/functions/account-age-gate` is called with the OAuth `provider_token`
(and/or `access_token`) the app got from `signInWithOAuth`. It:

1. resolves the account's creation date — **Gmail profile first**, Drive as fallback,
   recording which worked in `eligibility_checks.method`;
2. computes `account_age_days` and compares with `MIN_ACCOUNT_AGE_DAYS` (default **366**,
   never 365 — a non-leap year is one day short of a year);
3. writes `profiles.access_state` (`eligible`, `pending_verification`,
   `restricted`, `needs_reauth`, …) and the audit row via `app.request_role()` — the
   function's service-role client cannot bypass RLS by accident, because the RPC that
   writes switches role inside the transaction;
4. returns `{passed, access_state, reason, method, account_created_at, account_age_days,
   min_age_days, checked_at, sealing}`.

Rate limits are enforced in the function: **6 checks per user per minute**, 40 per IP
per minute, and only `MAX_ELIGIBILITY_ATTEMPTS` (5) *failing* attempts are allowed
before the account stays `pending_verification` until an admin or a passing check
resets it. A successful check is cached for `ELIGIBILITY_CACHE_DAYS` (30) and a
passing `checked_at` older than that makes the app's gate screen ask for a re-check —
the user-facing copy says exactly that.

**Failure mode you must decide on**: `AGE_GATE_ON_FAILURE=allow` (default) means a
Google outage cannot lock out established users; `deny` fails closed and every new
sign-in is `pending_verification` until Google answers. Flip it to `deny` before a
launch whose compliance story requires the rule to be absolute.

If you also want the check to survive a user deleting the Gmail grant, run
`account-age-gate` on a schedule (`recheck: true` in the body) from your cron of
choice; the RPC it uses is idempotent.

### 3.3 Testing the gate without a 1-year-old account

`eligibility_checks` is written by the function only, so use the function or the
service-role key in a script:

```bash
# A fresh account that should fail:
curl -s $SUPABASE_URL/functions/v1/account-age-gate \
  -H "authorization: Bearer $SERVICE_ROLE_KEY" -H 'content-type: application/json' \
  -d '{"accessToken":"…","requestId":"local-1"}'
```

For the app side, the fastest loop is to point `MIN_ACCOUNT_AGE_DAYS` at 0 locally
(the app only renders server-supplied copy; it never decides anything) and confirm
the gate screen disappears; then set it back to 366.

---

## 4. A hosted project, and what to deploy

```bash
supabase login
supabase projects create messengerx        # note the ref, e.g. abcdef12345
# → write it into supabase/.env (SUPABASE_PROJECT_REF), then:
make link                                 # supabase link + db push (asks for the DB password)
supabase secrets set \
  SUPABASE_URL=https://<ref>.supabase.co \
  SUPABASE_ANON_KEY=… \
  SUPABASE_SERVICE_ROLE_KEY=… \
  SUPABASE_JWT_SECRET=… \
  GOOGLE_WEB_CLIENT_ID=… GOOGLE_IOS_CLIENT_ID=… GOOGLE_ANDROID_CLIENT_ID=… \
  GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… \
  MIN_ACCOUNT_AGE_DAYS=366 MAX_ELIGIBILITY_ATTEMPTS=5 ELIGIBILITY_CACHE_DAYS=30 \
  AGE_GATE_ON_FAILURE=allow \
  SEAL_KEY="$(openssl rand -hex 32)" \
  BRIDGE_HMAC_SECRET="$(openssl rand -hex 32)" \
  BRIDGE_TOKEN="$(openssl rand -hex 32)" \
  BRIDGE_BASE_URL=https://bridge.internal.yourdomain \
  ALLOWED_ORIGINS=https://<ref>.supabase.co,io.messengerx.app,com.messengerx.app
make deploy                               # db push + the four functions
```

`make deploy` runs `supabase db push` first: the functions call RPCs that must exist,
and a function deployed against an old schema fails at the first write, not at boot.

Two deployment traps worth naming:

- **Do not** add `--no-verify-jwt`. The four functions need different protection, and
  `config.toml` already encodes it: three of them verify the user's JWT, and
  `telegram-ingest` sets `verify_jwt = false` because the bridge has no user JWT — it
  authenticates with `Authorization: Bearer $BRIDGE_TOKEN` **and** an HMAC signature.
  Copy that pair of settings into the hosted project (dashboard → Functions) if you do
  not deploy `config.toml` with the CLI.
- `SEAL_KEY` must be **the same 32 bytes** in the functions and in the bridge. If they
  differ, `telegram_link_submit` produces an envelope the bridge cannot open, TDLib is
  never called, and the user just sees the request expire — which looks like a Telegram
  outage. §7.3 is the playbook.

---

## 5. The Telegram bridge

### 5.1 Run it locally

```bash
cd services/telegram_bridge
cp .env.example .env          # or `make env` from the repo root
BRIDGE_TRANSPORT=memory npm run dev
```

With `memory` the worker starts a fake Telegram core: linking, code entry, sending,
read receipts and FLOOD_WAIT parking all behave as they do against the real thing, and
`SIM_PHONE_CODE` accepts a fixed code so you can walk the whole flow without a phone:

```
POST /healthz   → {"status":"ok","transport":"memory",…}
GET  /readyz    → 200 once sessions are restored; 503 while starting
GET  /metrics   → Prometheus text, prefix messengerx_bridge_*
POST /internal/wake  {"user_id":"<uuid>"}   # only with Bearer + HMAC
```

`/internal/wake` is what `telegram-send` calls after inserting an outbox row so a
message does not wait up to `BRIDGE_POLL_INTERVAL_MS` (default 1500 ms). Bodies over
64 KiB are refused with 413 — a wake payload is tiny on purpose. Any other path
returns 404 with no hint of what exists.

### 5.2 Real TDLib, against your own account

```bash
export BRIDGE_TRANSPORT=koffi        # or td_ws with a sidecar
export TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so
export TDLIB_DB_KEY="$(openssl rand -hex 32)"      # keep it in your secret manager
export TELEGRAM_API_ID=00000000
export TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
npm run build && npm start
```

(`TELEGRAM_API_HASH` from <https://my.telegram.org> → API development tools. One app
per deployment; never reuse a bot's app id, and never put the hash in the repo — it is
a secret despite the name `api_id` being public.)

Then in the app: **Telegram → Link account**, either *Scan this QR* (TDLib
`exportLoginToken`, rendered by `qr_flutter`, valid `TELEGRAM_QR_TIMEOUT_SECONDS`, 180 s
by default) or a phone number, then the 5-digit code Telegram sends to your other
device, then the 2FA password if you have one. Nothing but ciphertext crosses the
functions; the app never sees the phone credential after submit.

What to check when you do this for real (the CI suite cannot):

1. `telegram_accounts.auth_state = linked` and `last_inbound_at` advancing within ~3 s
   of a new Telegram message in a synced chat.
2. A message sent from MessengerX appears in Telegram with the same text, and the app
   bubble turns single-tick → double-tick → (after you read it in Telegram) read.
3. `tg_outbox` for that message reaches `delivered` — not stuck at `sent`. A row parked
   because of `FLOOD_WAIT_n` shows `leased_until` in the future and retries itself.
4. Reading the chat in *Telegram* clears the MessengerX badge (the reverse of #2).
5. Kill the worker (`^C`) and restart it: sessions are restored from `BRIDGE_DATA_DIR`,
   the link is still valid, and nothing is double-posted (idempotency is
   `(chat_id, source, tg_message_id)` for inbound and `dedupe_key` for outbound).

### 5.3 Configuration worth knowing

| Variable | Default | Why you would change it |
| --- | --- | --- |
| `BRIDGE_MAX_SESSIONS` | 200 | one worker holds ~200 TDLib clients comfortably; shard by user id beyond that |
| `BRIDGE_POLL_INTERVAL_MS` | 1500 | lower is more responsive, more CPU on the getUpdates loop |
| `BRIDGE_OUTBOX_BATCH_SIZE` | 25 | per tick per user |
| `BRIDGE_OUTBOX_LEASE_SECONDS` | 180 | a crashed worker's lease expires after this; keep > your worst media upload |
| `BRIDGE_MIN_SEND_INTERVAL_MS` / `BRIDGE_SEND_BURST` | 350 / 6 | Telegram's flood control; the worker parks instead of hammering |
| `INGEST_MODE` | `function` | `rpc` posts through the DB directly (service-role) — only for self-hosted installs without edge runtime |
| `TD_VERBOSITY` | 1 | 2 while debugging a link that stalls |
| `BRIDGE_TRANSPORT` | `koffi` | see §0 |

---

## 6. TDLib: version, image, sessions

- **Pin the version.** `services/telegram_bridge/Dockerfile` builds TDLib from a tag
  (`TDLIB_VERSION`, default `v1.8.43`) and the bridge was written against that schema.
  TDLib's JSON interface changes between minors; an unpinned image is how a routine
  rebuild starts failing every send. Upgrade deliberately: bump the arg, run
  `npm run test:bridge`, then §5.2's checklist against one real account.
- **Building locally** (macOS/Linux):
  `git clone --depth 1 --branch v1.8.43 https://github.com/tdlib/td && cmake -S td -B b -DCMAKE_BUILD_TYPE=Release && cmake --build b --target tdjson && sudo cmake --install b --component lib`
  then `export TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so`. On Apple Silicon set
  `-DCMAKE_OSX_ARCHITECTURES=arm64` or you will link an x86 library into an arm64
  process and `koffi` will fail with a confusing `dlopen` error.
- **Session state** lives in `BRIDGE_DATA_DIR/<user_id>/` — TDLib's own encrypted
  SQLite, keyed by `TDLIB_DB_KEY`. That directory plus the key is the *only* thing that
  keeps users logged in to Telegram across a redeploy: back it up like TLS keys,
  restore it before scaling a shard, and treat loss as "everyone re-links" (the app
  detects `needs_reauth` and says so).
- **No local database for the app.** MessengerX keeps its state in Postgres; the app's
  offline behaviour is "cached in memory for the session", not a local store. That is
  a product decision, not an oversight.

---

## 7. Operations

### 7.1 Signals

`GET /metrics` (Prometheus, `messengerx_bridge_*`) plus logs (pino JSON). The ones to
alert on:

| Metric / log | Alert when | It means |
| --- | --- | --- |
| `…_outbox_lag_seconds` | p95 > 10 s | the poll loop is behind or parked on FLOOD_WAIT |
| `…_outbox_parked` | > 0 for 15 min | a user is being rate-limited by Telegram; sends are waiting |
| `…_sessions_needs_reauth` | any | the TDLib session died (revoked, migrated, DB key rotated) |
| `…_ingest_rejected_total{reason="hmac"}` | rising | `BRIDGE_HMAC_SECRET`/clock skew mismatch between functions and bridge |
| `…_send_failed_total{code="…400"}` | rising | media path/policy problem — usually `images`/`voice-notes` prefix (see §7.3) |
| `GET /readyz` non-200 | 3 consecutive | the worker is not serving sessions; deploys must not proceed |

`/readyz` returns 503 until session restore finished, so a rolling deploy will not send
traffic to a cold worker. `/healthz` answers even while starting — use it for liveness
only.

### 7.2 Nothing is syncing — the 5-minute triage

Work the list in order; each step has a command and a decision.

```bash
# 1. Is the worker alive and at the right version?
curl -s $BRIDGE/healthz
# transport + sessions count. transport=memory in prod means the env did not apply.

# 2. Is it seeing rows to send at all?
psql "$DATABASE_URL" -c "select status, count(*), max(created_at) from public.telegram_outbox
                          group by 1 order by 2 desc"
# pending piling up + no `sent` → the poll loop is not running or the lease is held.
# leased_until in the future for many rows → a worker died mid-batch; wait for the
# lease (BRIDGE_OUTBOX_LEASE_SECONDS) or restart the worker.

# 3. Is the account's own state healthy?
psql "$DATABASE_URL" -c "select user_id, auth_state, sync_direction, last_inbound_at,
                          last_error_code from public.telegram_accounts order by last_inbound_at nulls first"
# needs_reauth / revoked → the user must re-link; no server action will fix it.
# linked but last_inbound_at stale → inbound is the problem, not outbound:
#   does the chat mapping exist?  select * from public.telegram_chats where user_id = …;

# 4. Are the bridge's writes reaching the DB?
psql "$DATABASE_URL" -c "select created_at, kind, error from public.telegram_inbox_events
                          order by created_at desc limit 5"
# rows landing but not in `messages` → the ingest RPC is failing; check the function
# logs for a rejected signature (401) rather than a DB error.
```

### 7.3 The three failures that actually happen

**A. Link request expires without a reason visible to the user.** Almost always a seal
mismatch: `SEAL_KEY` differs between `telegram-link` and the bridge, or the request
sat longer than its TTL. `telegram_link_requests.expires_at` defaults to **10 minutes**
and `guard_link_request_insert` (00005) clamps anything a writer asks for beyond 15
minutes, so a queued request that the bridge never claims simply expires. Confirm with:

```bash
psql "$DATABASE_URL" -c "select id, status, step, created_at, expires_at,
                          (expires_at < now()) as expired from public.telegram_link_requests
                          order by created_at desc limit 10"
```

If `status` is stuck at `queued`, no worker is claiming it: the worker is down, it is
pointed at another project, or `BRIDGE_MAX_SESSIONS` has been reached. If it reached `awaiting_user` and
stayed there, the user's device never completed the flow — that is a UX question, not an
incident. Credentials never live in those rows: the payload column holds the AES-GCM
envelope `{alg,iv,ct}` and the guard forbids reading a plaintext back out, so an
expired request leaks nothing. (A `plain` envelope is only accepted when
`MESSENGERX_ENV=development`; the bridge refuses it in production and the app's link
screen shows a loud warning instead of pretending to be safe.)

**B. Media uploaded but the bubble is broken.** The bucket layout is enforced by the
storage policies in 00008 and the object key is part of the message contract:

- `avatars/<user_uuid>/…` — the sender's own prefix; public read.
- `images/<chat_uuid>/…` and `voice-notes/<chat_uuid>/…` — the **chat's** uuid, not the
  sender's. Telegram-originated files are written by the bridge under
  `images/<chat_uuid>/tg/<tg_chat_id>-<tg_message_id><ext>` (same for `voice-notes`).

A message whose `media->>'path'` does not start with the right prefix is a
`403`/`404` on download even though `messages.media` validated fine — `app.validate_message_media` checks the *shape* (`bucket`, `path`, `mime`, sizes, the 64-bar `waveform` for
voice), not the folder. So: same prefix in both directions, or nothing renders. When
you add a new media kind, add its folder to 00008-style policies in a new migration and
to the validator, and extend `tools/sql-test/run.mjs` with both the accepted and the
rejected prefix.

**C. "Messages sent twice" or "the tick never turns blue".** Both are correlation
bugs, and the fix is always the same: correlate by an id, never by content. Inbound
dedupe is `(chat_id, source, tg_message_id)`; outbound is the client-generated
`client_message_id`, which the app inserts optimistically and then *replaces in place*
when the realtime event arrives (position preserved, so the list does not jump). The
bridge's `tg_outbox` row id is TDLib's `sending_id`, and the echo of an outbound message
carries `sending_state.sending_id ?? message.sending_id`; a message with no `sending_id`
is unmatched and gets re-fetched once rather than guessed at by text. If you find
yourself matching on sender+body, stop and add the id.

### 7.4 Rotation and maintenance

- **`BRIDGE_TOKEN` / `BRIDGE_HMAC_SECRET`**: rotate in the functions' secrets first,
  then the bridge's, restarting the worker. A worker holding an old secret fails
  closed (401), which is the safe direction; requests in flight during the window are
  retried by the poll loop, so a rotation needs no freeze. Both secrets must be ≥ 32
  bytes or startup refuses (`config.ts` validates).
- **`SEAL_KEY`**: rotate only with no in-flight link requests (check
  `telegram_link_requests` for `status in ('queued','claimed','awaiting_user')`),
  because a request sealed with the old key becomes undecryptable — the user sees an
  expiry, which is acceptable, but a mid-submit failure is not.
- **`TDLIB_DB_KEY`**: changing it invalidates every session. Plan it as a re-link
  event for all users; there is no re-wrap path.
- **Pruning**: `messages.search_tsv` is maintained by trigger; nothing grows without a
  bound except `telegram_inbox_events` (audit-only, no client policies). Prune it on a
  schedule if you keep the bridge for long:
  `delete from public.telegram_inbox_events where created_at < now() - interval '30 days';`
- **Backfill**: to replay a chat's Telegram history after a mapping was lost, set
  `sync_direction` to `backfill` for that `telegram_chats` row and let the worker walk
  `getHistory` — inbound idempotency makes a re-run safe, so start with a generous
  window rather than guessing exactly where it stopped.

---

## 8. Changing the schema

Rules that come from how these migrations are loaded and tested:

1. **Never edit an applied migration.** Add `000XX_….sql`. Local `db reset` replays all
   of them in order, so a hand-edited early migration silently diverges from production.
2. **A migration that creates or replaces a function owns its grants.** 00009 holds the
   baseline `revoke … from public / grant … to authenticated, service_role`, and
   Postgres drops grants with the old function object — 00011 (`update_profile` +
   `p_clear_avatar`) is the worked example.
3. **RPCs clients call must be `security definer` with `set search_path = pg_catalog, public`**
   and must derive the caller from `app.current_uid()`, never from an argument. Any
   SECURITY DEFINER function you add without a `search_path` is a privilege-escalation
   bug, and the seed check would not catch it.
4. **Do not `force row level security`** on tables the bridge reads with the
   service-role key; the bridge relies on `app.is_service_role()` inside its own
   policies instead.
5. **Anything the app streams must be added to the publication** in the same migration
   (`alter publication supabase_realtime add table …`), and must have a policy that
   filters per member — Realtime respects RLS, so a missing policy means a silent
   stream, not a leak.
6. Keep `seed.sql` to ≤ a handful of statements: `tools/sql-test/seed-check.mjs` splits
   on `/;\s*\n/` and asserts the fixture set (5 statements / 8 checks). Its job is to
   catch a seed that quietly started depending on something the migrations do not
   create.
7. Add the behaviour to `tools/sql-test/run.mjs` in the same commit, including the
   negative case — the suite's value is that a policy which stops enforcing shows up as
   a red assertion instead of a data leak. `cd tools/sql-test && node run.mjs`, and
   remember the two suites share ids `1111…`–`6666…` for their fixtures.

`npm run test:sql && npm run test:seed` is the fast half (no Docker); `make db-reset`
is the "does this boot a real Supabase" half.

---

## 9. Troubleshooting by symptom

| Symptom | First thing to check | Then |
| --- | --- | --- |
| App boots straight to a red "build not configured" | `SUPABASE_URL`/`SUPABASE_ANON_KEY` in `.messengerx/app.json` | `appEnv.validate()` fails loudly by design — no default project is baked in |
| Sign-in spins, then "Google refused" | Android SHA-1 / iOS bundle id registered on the client | Supabase → Auth → Google provider enabled; redirect URI registered in Google |
| Signed in, stuck on the gate screen | `select access_state, access_state_reason from profiles where id = …` | `AGE_GATE_ON_FAILURE=deny` during a Google outage; 5 failed attempts locks until an admin clears it |
| Gate says "recheck" forever | `eligibility_checks.checked_at` vs `ELIGIBILITY_CACHE_DAYS` | Gmail grant revoked → `needs_reauth` is correct; re-consent |
| No live messages, but pull-to-refresh works | Realtime channel in the logs; `PostgresChangeFilter` on `chat_id` | publication membership (00008) and the member policy; a chat row for a non-member streams nothing |
| Voice note records, then the bubble shows a retry arrow | `images`/`voice-notes` upload policy: folder must be the **chat** uuid | the 10 MiB limit; `duration_ms`/`waveform` shape (`22023` = media contract) |
| Message says "attachment not in a shape MessengerX accepts" | `app.validate_message_media` (`00004`) | the client is constructing media the contract does not include — fix the client, do not widen the validator for a UI convenience |
| Sends work, reads never arrive | `telegram_accounts.last_inbound_at`; `TD_VERBOSITY=2` | ingest 401s (HMAC/skew) or `INGEST_MODE` mismatch |
| Everything stalls after a deploy | `/readyz` 503? `BRIDGE_DATA_DIR` mounted? | `TDLIB_DB_KEY` changed → sessions unreadable → all accounts `needs_reauth` |
| Bridge restart loop | startup validation output (it refuses to boot with a weak/missing secret, on purpose) | `openssl rand -hex 32` for the three trust secrets |
| One user cannot be helped remotely | that user's `telegram_accounts.auth_state` | `revoked`/`needs_reauth` → unlink from the profile screen, then re-link; no server-side workaround exists for a dead TDLib session |

Admin surface on purpose: the bridge exposes **only**
`GET /healthz`, `GET /readyz`, `GET /metrics`, `GET /sessions` (counts, no identifiers
unless `MESSENGERX_ENV != production`) and `POST /internal/wake`. There is no "resync
this user" HTTP verb: resync by writing the row that makes the worker pick it up, so
every admin action is auditable in the same table as everything else.

---

## 10. Deliberately absent

Not oversights — decisions, so nobody re-litigates them at 2 a.m.:

- **Bot API**: cannot read a *personal* chat history, which is what "two-way sync with
  my Telegram" means here.
- **GramJS as an adapter**: see §0.
- **Push notifications**: the app reads `unread_total()` and Realtime; APNs/FCM is a
  separate service that should not be bolted onto this runbook.
- **End-to-end encryption**: transport security + RLS only. Media is decrypted by the
  bridge for mirroring; that is inherent to a userbot.
- **Server-side offline queue**: no local store in the app (§6).
- **In-app phone sign-in**: the phone number exists only inside the link flow.
