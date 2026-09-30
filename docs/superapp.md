# MessengerX Super-App — build plan and architecture

Status: **in progress** (started 30 September 2026). This document is the contract
the rest of the repository is built against: schema, edge functions, app screens,
tests and the demo videos all follow it. Anything in here that is not yet true in
the code is listed in the honesty table at the end — the same rule the README
follows.

## 1. The product in one paragraph

One $0-tier application that combines the four things people actually use every
day: **long-form video** (YouTube: home grid, search, chapters, watch page with
comments), **short vertical video** (TikTok: full-screen swipe feed, For You /
Following), **messaging** (Telegram: fast real-time chats, media, channels) and
**communities with identity** (Discord: servers, channels, roles, unique handles
and profile tags). The four live in one bottom bar so nothing is duplicated or
hidden behind a maze.

```
┌───────────────────────────────────────────────────────────────┐
│  [logo]  MessengerX                        [ 🔍 search ]      │  ← top: brand + search
├───────────────────────────────────────────────────────────────┤
│  For you   │   Following        ← the same two tabs everywhere │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│   HOME  = long-form video grid (YouTube)                       │
│   REELS = short vertical video (TikTok)                        │
│                                                               │
│                                                               │
├───────────────────────────────────────────────────────────────┤
│   Home      Reels      ( + )      Messages      You            │  ← bottom bar (TikTok control panel)
└───────────────────────────────────────────────────────────────┘
```

Trust boundaries, unchanged from the original design: Supabase Postgres + RLS is
the only source of truth for identity, membership and money; Backblaze B2 holds
video bytes and is reached only through presigned URLs minted by an edge
function; the client never sees a service-role key, a Stripe secret or an S3
secret.

## 2. Design system (one file, one truth)

`apps/mobile_app/lib/app/design.dart` holds every token, so the four product
surfaces cannot drift apart:

| Token group | Values |
| --- | --- |
| Brand | `X` monogram (geometric, high contrast, works on both themes) |
| Surfaces | `#0B0D10` ink, `#14171C` panel, `#1C2027` raised (dark) / `#FFFFFF`, `#F4F6F9` (light) |
| Accent | `#3B82F6` primary, `#F43F5E` live/record, `#22C55E` online, `#F59E0B` stars |
| Type | Roboto; display 28/700, title 18/600, body 15/400, meta 12/500 |
| Radii | card 16, sheet 22, pill 999, bubble 18 (tail 6) |
| Motion | 180 ms standard, 90 ms exit; reels snap with `PageView` physics |

Rules that keep the UI from becoming confusing:

1. **One bottom bar for the whole app**, no exceptions, no nested bars. It is
   auto-hidden only inside the Reels player and the chat thread, where the
   content owns the full screen (both restore on any upward drag / back).
2. **Two feed tabs, always in the same place**: `Home` and `Reels` each carry
   `For you` / `Following` as the first element under the top bar.
3. **Messages is a single list of conversations** (Telegram model) where a
   *server* opens as a room with a channel rail, and *bots* are conversations
   like any other. Bots are never a separate screen.
4. **Create is one sheet** with five entries: Short, Video, Voice-over, Story,
   Message — every entry says what it produces before it asks for a file.

## 3. Data model (migrations 00020 – 00022)

### 3.1 Identity, tags and stars (`00020`)

* `profiles.discriminator` — four digits, unique per `username_norm`; the handle
  everyone sees is `aziz#4821`. Changing a username is rate-limited (30 days)
  and re-rolls the discriminator.
* `tags` / `user_tags` / `profiles.tag_id` — Discord-style badges
  `[GRAND]` rendered next to every username the app draws. Free tier owns one
  slot, Plus three, Elite five (slots are settings-driven).
* `star_ledger` + `profiles.star_balance` / `lifetime_stars` — Telegram-Stars
  style balance. `app.stars_apply()` is the **only** writer: an append-only
  ledger row plus a cached balance, idempotent on `(user_id, idempotency_key)`.
  Every grant/spend/refund is one call to it.
* `payments` — Stripe sessions. Created by the `stripe-checkout` edge function
  (service role), settled by `stripe-webhook` through
  `public.fulfill_payment()`, which is idempotent on the session id.
* `platform_settings` — the $0 beta switches: `payments.stripe_enabled=false`
  plus `stars.daily_grant=25` means every account can earn and spend stars for
  free while tag creation still costs stars, so the mechanic is testable before
  a single payment is taken.
* `notifications` — follows, likes, comments, tips, bot mentions; the Messages
  tab shows them with an unread badge (TikTok/YouTube behaviour).

### 3.2 Social graph and content (`00021`)

* `follows` — the source of the `Following` tab on both feeds.
* `videos` — long-form (title, description, chapters JSON, thumbnail key,
  visibility, view/like/comment counters, `search_tsv`). Vertical content stays
  in the existing `shorts` table, so the phase-1 tests keep their meaning.
* `content_comments` / `comment_likes` — **one** comment system for both
  surfaces, keyed by `(subject_kind, subject_id)`, with nested replies, pins,
  author-only deletes and counters maintained by triggers.
* `content_views` — a view is one row per viewer per subject per day, and the
  counter is a trigger; that is what makes "views" honest instead of a
  refresh-driven number.
* `feed_videos()` / `feed_shorts()` / `search_content()` — the three read paths
  the Home tab, the Reels tab and the top search bar use, each returning the
  author projection (handle, badge, avatar, follower flag) in one round trip.

### 3.3 Communities, bots and voice (`00022`)

* `chats.is_server` + `chats.parent_chat_id` — a server is a chat; its channels
  are chats whose parent is that server. `app.is_chat_member()` is redefined to
  inherit membership from the parent, so every existing policy (chats,
  participants, messages, storage) keeps working unchanged.
* Roles (`owner/admin/member`) and timeouts (`chat_participants.timeout_until`)
  give Discord mechanics without a second permission system.
* `bots` / `bot_commands` / `bot_installations` / `bot_events` — the "@BotFather"
  model: a user creates a bot in a conversation, receives a token **once**, and
  the bot can then post, react to `/commands`, answer mentions and be scheduled.
  `bot_events` is the durable queue the runtime drains; it is written by the same
  `app.after_message_write` trigger the Telegram outbox uses, so a bot never
  misses a message because an edge function was cold.
* `ai_voice_usage` — the TikTok-style AI voice-over is synthesised **on the
  device** (no API key, no per-token cost) and this table is the free daily
  quota the server enforces, so the feature cannot be farmed.

## 4. Money: free by default, paid when the operator is ready

| Item | Free path ($0) | Paid path |
| --- | --- | --- |
| Video storage | Backblaze B2 free tier (10 GB) + direct-to-B2 presigned PUT | — |
| Database / auth / realtime | Supabase Free | — |
| Web site | Vercel Hobby static build | — |
| AI voice-over | on-device TTS, daily quota in `ai_voice_usage` | — |
| Tags, tips, badges | daily star grant (`stars.daily_grant`) | Stripe Checkout, $2.49 → 100 stars |
| Bots | Vercel/Supabase edge runtime, `bot_events` queue | — |

`payments.mode` is `beta_free` out of the box. Stripe is *implemented and
tested* (checkout session, webhook signature verification, idempotent
fulfilment), and switches on by setting `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET` and `payments.stripe_enabled=true`. No client build ever
contains a payment secret, and `paid` is only ever written by the webhook.

## 5. Build order (what lands in which commit)

1. `00020` identity/tags/stars/payments/notifications + tests — **this commit**
2. `00021` follows, long-form video, comments, views, feeds + tests
3. `00022` servers/channels, bots, AI-voice quota + tests
4. Edge functions: `stripe-checkout`, `stripe-webhook`, `bot-bridge`, `video-ticket` v2 (long-form scope)
5. Flutter: `design.dart`, app shell, Home, Reels, Comments, Profile (/handle)
6. Flutter: Messages (servers/channels/bots), Create sheet, Settings, search
7. CI, docs, demo videos (narrated walkthrough + promo), release notes

## 6. Honesty table

| Claim | State today |
| --- | --- |
| New UI, five-tab shell, YouTube-style home, TikTok-style reels, Telegram-style messages, Discord-style tags | In progress — see §5 for the commit that lands each |
| Stores / channels / bots | Schema + RPCs land in `00022`; app surfaces follow |
| Stripe $2.49 → 100 stars | Implemented and unit-tested; **inactive** until the operator sets the three secrets |
| Android release for everyone | Built by CI as a debug APK; a Play Store release needs the operator's signing key |
| iOS | Same source builds and runs (PWA today); an App Store build needs an Apple Developer account |
| "100% functional perfection" | Not a claim this repository makes. Every feature above is covered by the SQL/edge/Flutter test suites and listed honestly here |
