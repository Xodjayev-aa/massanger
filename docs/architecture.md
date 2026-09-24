# MessengerX architecture

One page for the contracts, so nobody has to read twelve migrations to change
something. The operational side (provisioning, incidents) is in
[runbook.md](runbook.md); this file is about *why the pieces fit the way they do*.

## Shape

```
apps/mobile_app          Flutter, flutter_bloc + go_router + get_it
supabase/migrations      the whole data model, RLS, RPCs, triggers, storage, realtime
supabase/functions       4 edge functions (Deno): age gate, link, send, ingest
services/telegram_bridge long-lived Node worker: TDLib sessions, outbox, Saved Messages notices, ingest
docs/ infra/ Makefile    runbook, compose wiring, task entry points
tools/                   typecheck configs + the PGlite suites
```

**Contract-bearing writes and feed projections use RPCs.** Reads such as
`chat_summaries`, `chat_feed`, `search_messages`, `unread_total`,
`chat_typing_state`, `eligibility_status` and `telegram_link_state` give the app
stable projections. Writes like `send_message`, `mark_chat_read`,
`telegram_set_preferences` and `set_push_preferences` enforce cross-row rules in
one transaction. Select self-scoped `profiles`, `telegram_chats`, directory and
`chat_participants` rows through RLS where only a small projection is needed; the
foreground banner rechecks the latter before showing any content. A chat mute is
an RLS-scoped update of **only the caller's participant row** and the notice
cancellation trigger enforces its immediate effect. A client-owned insert into
`messages` could not enforce reply identity, sender snapshot, media validation and
outbox/notice queue atomically. The sensitive queues have no client policies:
`notify_requests` in particular is never directly visible to the app.

## The message path

**Out (app → Telegram mirror).** `send_message(p_chat_id, p_kind, p_body, p_media,
p_reply_to_id, p_client_message_id)` runs as the caller, checks
`app.sender_may_post`, snapshots the sender's display name, validates `p_media` against
`app.validate_message_media` (errors as SQLSTATE `22023`, which the client renders as
"attachment not in a shape MessengerX accepts"), and — if the chat mirrors to Telegram —
inserts the `telegram_outbox` row **in the same transaction**. That atomicity is the whole
point: there is no window where a message exists in MessengerX but was never going to be
sent. The client already showed an optimistic bubble keyed by `client_message_id`; the
RPC returns the real row and the client *replaces in place* when the realtime echo
arrives, matched on `client_message_id`, never on content.

**Out (worker → Telegram).** The bridge claims `telegram_outbox` rows with
`FOR UPDATE SKIP LOCKED` and an `in_flight` lease, so two workers cannot take the same row,
calls TDLib, and uses the returned `sending_id` — which is the outbox row's id — as the
correlation key for the `updateMessageSendAcknowledged` / `updateNewMessage` echo.
`FLOOD_WAIT_n` parks the row (`next_attempt_at = now() + n + 2s`) instead of failing it;
`AUTH_KEY_UNREGISTERED`, `SESSION_REVOKED`, `USER_DEACTIVATED` move the account to
`needs_reauth`, which is a state the app can show and act on.

**In (Telegram → app).** The worker writes `telegram_inbox_events` and posts them to
`telegram-ingest`, which is the one function with `verify_jwt = false`: the bridge has
no user JWT, so it authenticates with a bearer token **and** an HMAC over the body, and
the function enforces both. Inbound dedupe is `(chat_id, source, tg_message_id)`;
media is written to `images/<chat>/tg/<tgChatId>-<tgMessageId><ext>` so the download
policies see exactly the same shape as app-uploaded media.

## Notifications without APNs/FCM

Migration `00012_self_push.sql` creates a distinct `notify_requests` queue. The
message AFTER trigger queues **for an offline recipient**, never for the author:
active profile with `push_telegram`, linked Telegram account, heartbeat older than
90 seconds (app beats every 45 seconds), unread unmuted membership, non-system
message. One `queued` row per `(user, chat)` holds the latest preview and a fold
count. A 3-second quiet window reduces burst noise. A Telegram-sourced row does
not queue if this recipient already mirrors that chat *from* Telegram — their own
Telegram already saw it. Reads, mute/leave, foreground heartbeats and turning
push off cancel pending notices; a preview switch scrubs both queued and leased
text. The queue's RLS has **no client policies**; only the bridge service role can
claim or complete its rows.

The manager polls/leases this queue separately from `telegram_outbox`, groups rows
by **recipient** and uses that person's existing TDLib session to send one text
to Saved Messages. `bridge_notice_owed` rechecks the lease, read, mute, presence,
Telegram-source duplication **and the claimed preview** immediately before send;
this last check is what prevents a stale in-flight preview from leaking after a
privacy change. The result caches a self-chat id; relinking a different Telegram
identity resets the cache. FLOOD_WAIT parks, bad peer ids reset it, revoked auth
fails the queue. Saved Messages registration, echoed updates, deletions and read
receipts are all excluded from app mirroring. In-memory recovery avoids resending
if only the DB completion failed, but a worker crash between the Telegram send
and the DB write is *at least once*, not a mathematical exactly-once guarantee.

While the app is **resumed**, the `IncomingNotices` host listens for Realtime
message INSERTs. It skips own/system/open-thread rows, consults the participant
for unread/mute, suppresses already-delivered Telegram-source traffic, fetches
`push_preview` afresh (fails closed), folds successive events per chat and shows a
5-second local banner. It unsubscribes on pause; `chat_summaries` unread badges
cover anything missed. A banner tap dismisses; no notice deep link is wired.
Telegram itself may suppress an OS notification for a self-sent Saved Messages
entry: this architecture delivers *content* to Telegram, **not** an assured iOS
or Android system push. See [the device smoke test](runbook.md#52-real-tdlib-against-your-own-account).

## Delivery states

`pending → sending → sent → delivered → read`, plus `failed`, stored on the message and
advanced only by monotonic rank (`app.delivery_state_rank`) with one exception a
trigger enforces: anything may move to `failed`. A client never writes a receipt; it
calls `mark_messages_delivered(p_message_ids)`, which only marks *other people's*
messages in chats the caller belongs to, and reads are `mark_chat_read`. In Telegram
terms: reading in MessengerX produces `viewMessages`, reading in Telegram clears the
MessengerX badge — the same event through the inbound path.

## Presence

`chat_typing` rows are transient state, not history: `set_typing(p_chat_id, p_on,
p_action)` upserts (the app throttles to one call per 2.5 s and re-asserts every 5 s),
the row expires by `heartbeat()` + a pruning path, and `chat_typing_state(p_chat_id)`
returns who is typing *now*. Turning typing off deletes the row rather than flipping a
flag, so a killed app cannot leave someone "typing" forever. The bridge forwards typing
in both directions only when the account's preferences allow it
(`bridge_pending_typing` exposes exactly the rows that are safe to forward).

## Trust and identity

- **Auth is Google-only** in the client. `signInWithOAuth` hands the app a
  `provider_token`, which goes to `account-age-gate`; the gate resolves the Google
  account's creation date (Gmail `users.getProfile`, Drive `about` as fallback), and
  writes `profiles.access_state`. The app renders the state; it never decides it. The
  rule is `MIN_ACCOUNT_AGE_DAYS = 366`, with `MAX_ELIGIBILITY_ATTEMPTS = 5` failures
  cached for `ELIGIBILITY_CACHE_DAYS = 30`.
- **Navigation is gated on `access_state`**, in the router, from a single refresh
  listenable — a `restricted` account can read its own profile and nothing else.
- **Telegram credentials are sealed per request.** The app calls `telegram-link`
  (action `start`/`submit`/`status`/`cancel`/`unlink`); the function writes an A256GCM
  envelope `{alg,iv,ct}` into `telegram_link_requests.payload`, the bridge decrypts it in
  memory and feeds TDLib, and `guard_link_request_{insert,update}` keeps the payload
  write-once and the expiry within 15 minutes. The direct tables
  (`telegram_link_requests`, `telegram_accounts` credentials) have no client policies at
  all: a wrong `select` from the app is a `42501`, not a partial read.
- **Storage is partitioned by ownership**: `avatars/<uid>/…` (public read, so the app
  uses `getPublicUrl`), `images/<chat>/…` and `voice-notes/<chat>/…` (signed URLs only,
  policy checks `folder(1) = chat_id` and the caller is a member).

## State management

`flutter_bloc` for anything with a lifecycle the user can interrupt (auth, chats list,
one open chat, Telegram linking) and `Cubit` where there is only one async operation
(profile, telegram preferences). Optimistic UI lives in the bloc, not the widget tree,
so a rebuild cannot lose a pending bubble, and every failure path has a named retry
event (`ChatMessageRetryRequested`, `ChatsRefreshRequested`,
`AuthProfileRefreshRequested`) rather than a toast that disappears. `ChatBloc` owns the
realtime subscription and the typing timer and cancels both in `close()`; the router is
built once at startup so a `refreshListenable` redirect does not rebuild the navigator
and throw away a half-typed message.

Dependencies are resolved through a `get_it` locator configured in `main.dart`
(repositories, services, bloc observers) so a widget test can swap `ChatRepository` for a
fake without touching production wiring, and so `AppEnv` (compile-time `--dart-define`)
is the only global.

## Invariants worth keeping

1. Idempotency keys before retries: `client_message_id` (app), `dedupe_key` (outbox),
   `(chat_id, source, tg_message_id)` (inbound). Anything retried must be addressable.
2. Correlate by id, never by content — text can be edited, truncated or translated.
3. Media shape is validated server-side; media *location* is enforced by policy. Both
   must agree or the UI shows a broken asset that validated fine.
4. A new migration owns its grants and its publication membership.
5. Triggers enforce what a client could otherwise race (sender snapshot, `search_tsv`,
   unique direct pair, delivery rank, profile field guards).
6. Secrets fail closed at startup and the app refuses to look safe when it is not
   (`MESSENGERX_ENV=production` rejects a `plain` link envelope; the bridge refuses
   short trust values).

## Testing

| Suite | Runs | Covers |
| --- | --- | --- |
| `npm run test:sql` | PGlite, no Docker | 79 assertions: RLS, RPCs, notice queue folding, read/mute/privacy, retries |
| `npm run test:seed` | PGlite | seed applies in 5 statements and the fixtures stay consistent |
| `npm run test:bridge` | `node --test`, memory transport | 102 assertions: auth, sends, notices/self-chat isolation, flood wait, media, ingest, admin HTTP |
| `npm run typecheck:functions` | `tsc` + `tools/typecheck/deno-shims.d.ts` | the Deno functions against the same lib surface |
| `flutter test` | `flutter_test`, requires Flutter SDK | media jsonb contract, timestamps/bigints, waveform, `AppEnv` startup and notification preference/direction parsing; not run in this sandbox |
| `flutter analyze` | analyzer, requires Flutter SDK | strict casts/inference/raw types, `avoid_print` and `unawaited_futures` as errors; not run in this sandbox |

There is no test that talks to Telegram, and that is the design: everything up to the
TDLib boundary is deterministic, and the boundary itself is one interface
(`TdLibTransport`) whose real implementations are verified by the checklist in
[runbook.md §5.2](runbook.md).
