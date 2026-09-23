# Massanger architecture

One page for the contracts, so nobody has to read eleven migrations to change
something. The operational side (provisioning, incidents) is in
[runbook.md](runbook.md); this file is about *why the pieces fit the way they do*.

## Shape

```
apps/mobile_app          Flutter, flutter_bloc + go_router + get_it
supabase/migrations      the whole data model, RLS, RPCs, triggers, storage, realtime
supabase/functions       4 edge functions (Deno): age gate, link, send, ingest
services/telegram_bridge long-lived Node worker: TDLib sessions, outbox, ingest
docs/ infra/ Makefile    runbook, compose wiring, task entry points
tools/                   typecheck configs + the PGlite suites
```

The app talks to **RPCs, not tables**. Every read it needs is a function
(`chat_summaries`, `chat_feed`, `search_messages`, `unread_total`,
`chat_typing_state`, `eligibility_status`, `telegram_link_state`) and every write is a
function (`send_message`, `create_direct_chat`, `mark_chat_read`,
`mark_messages_delivered`, `retry_message`, `delete_message`, `set_typing`,
`update_profile`, `telegram_set_preferences`, `telegram_set_chat_sync`,
`telegram_unlink`). Two reasons, both practical: a query the client owns cannot
enforce an invariant (the reply target, the sender snapshot, the media contract, the
outbox row written in the same transaction), and a table the client selects from
directly makes the realtime payload wider than the feed and leaks future columns the
moment someone adds them. Row-level security is the second line, not the first.

## The message path

**Out (app → Telegram mirror).** `send_message(p_chat_id, p_kind, p_body, p_media,
p_reply_to_id, p_client_message_id)` runs as the caller, checks
`app.sender_may_post`, snapshots the sender's display name, validates `p_media` against
`app.validate_message_media` (errors as SQLSTATE `22023`, which the client renders as
"attachment not in a shape Massanger accepts"), and — if the chat mirrors to Telegram —
inserts the `tg_outbox` row **in the same transaction**. That atomicity is the whole
point: there is no window where a message exists in Massanger but was never going to be
sent. The client already showed an optimistic bubble keyed by `client_message_id`; the
RPC returns the real row and the client *replaces in place* when the realtime echo
arrives, matched on `client_message_id`, never on content.

**Out (worker → Telegram).** The bridge claims a batch of `tg_outbox` rows with a lease
(`FOR UPDATE SKIP LOCKED` + `leased_until`), so two workers cannot take the same row,
calls TDLib, and uses the returned `sending_id` — which is the outbox row's id — as the
correlation key for the `updateMessageSendAcknowledged` / `updateNewMessage` echo.
`FLOOD_WAIT_n` parks the row (`leased_until = now() + n`) instead of failing it;
`AUTH_KEY_UNREGISTERED`, `SESSION_REVOKED`, `USER_DEACTIVATED` move the account to
`needs_reauth`, which is a state the app can show and act on.

**In (Telegram → app).** The worker writes `telegram_inbox_events` and posts them to
`telegram-ingest`, which is the one function with `verify_jwt = false`: the bridge has
no user JWT, so it authenticates with a bearer token **and** an HMAC over the body, and
the function enforces both. Inbound dedupe is `(chat_id, source, tg_message_id)`;
media is written to `images/<chat>/tg/<tgChatId>-<tgMessageId><ext>` so the download
policies see exactly the same shape as app-uploaded media.

## Delivery states

`pending → sending → sent → delivered → read`, plus `failed`, stored on the message and
advanced only by monotonic rank (`app.delivery_state_rank`) with one exception a
trigger enforces: anything may move to `failed`. A client never writes a receipt; it
calls `mark_messages_delivered(p_message_ids)`, which only marks *other people's*
messages in chats the caller belongs to, and reads are `mark_chat_read`. In Telegram
terms: reading in Massanger produces `viewMessages`, reading in Telegram clears the
Massanger badge — the same event through the inbound path.

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
   (`MASSANGER_ENV=production` rejects a `plain` link envelope; the bridge refuses
   short trust values).

## Testing

| Suite | Runs | Covers |
| --- | --- | --- |
| `npm run test:sql` | PGlite, no Docker | 59 assertions: RLS matrix, RPC behaviour, trigger invariants, enum clamps |
| `npm run test:seed` | PGlite | seed applies in 5 statements and the fixtures stay consistent |
| `npm run test:bridge` | `node --test`, memory transport | 87 assertions: auth state machine, lease/claim, flood parking, media prep, ingest, presence, admin HTTP |
| `npm run typecheck:functions` | `tsc` + `tools/typecheck/deno-shims.d.ts` | the Deno functions against the same lib surface |
| `flutter test` | `flutter_test` | the contracts nothing else checks between Dart and Postgres: the media jsonb shape `app.validate_message_media` expects, timestamp/bigint coercion, the 64-bar waveform scale, `AppEnv` start-up validation |
| `flutter analyze` | analyzer | strict casts/inference/raw types, `avoid_print` and `unawaited_futures` as errors |

There is no test that talks to Telegram, and that is the design: everything up to the
TDLib boundary is deterministic, and the boundary itself is one interface
(`TdLibTransport`) whose real implementations are verified by the checklist in
[runbook.md §5.2](runbook.md).
