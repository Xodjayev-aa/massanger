# MessengerX

One Flutter app over one Supabase Postgres: a **video platform** (long-form
grid, reels, comments, watch history), a **messenger** (direct and group chats,
reactions, polls, scheduled sends, TTL), **Discord-style communities** (roles,
channel permissions, voice rooms), **Telegram-style broadcast channels and
bots** (including the platform-side @BotFather and a unified bot API), and a
**free Stars economy** with $2.49 custom profile tags paid through Stripe.

This repository is a work-in-progress application, **not a publicly deployed
service**.

## What exists today (30 September 2026)

Everything below was written against the same database, and every server-side
rule is exercised by the test suites in `tools/`. The Flutter client was
rewritten in this pass; **no local Flutter SDK was available in this sandbox, so
CI is the first place the client itself is compiled** — treat the client as
unverified until the `flutter` job is green.

### The video product

| Surface | Honest status |
| --- | --- |
| Long-form video feed (For You / Following / Trending / category) | SQL RPCs (`video_feed`, `author_videos`, `video_detail`) tested. Ranked by views/likes/comments with a keyset cursor. |
| Reels | `shorts_feed` (For You, Following, sound, saved, profile), `rate_short`, view/save/share counters, duet/stitch reply kinds — tested. |
| Watching | Custom player with position-delta watch tracking, Watch Later, history, chapters, sound attribution, nested comments. |
| Uploads | Device-side MP4 validation → **presigned PUT straight to Backblaze B2** → `video-ticket confirm` re-reads size, `moov`/`mvhd` duration and magic bytes before any row is written. Posters (JPEG/PNG) go through the same ticket. |
| AI voice-over (TikTok's feature) | The script is stored on the `sounds` row (`origin = 'tts'`, `voice_script`) and **re-rendered by the device's own speech engine** — no paid TTS service and no audio upload. Composer + sound page implemented; not device-tested. |
| Comments | Threaded replies, likes, pinning, hearts, per-video moderation — tested. |

### The social and community product

| Surface | Honest status |
| --- | --- |
| Follows, requests, blocks | `00020` graph with pending private-account requests; tested. |
| Custom profile tags (the $2.49 product) | `00025`: mint via a Stripe-earned credit or Stars, style shelf, server-side text sanitising, five slots — tested. |
| Stars economy | Wallet, ledger, gifts/tips (100% to the creator), cosmetics, payout requests, refunds — tested. |
| Stripe pipeline | `stripe-checkout` + `stripe-webhook` (Edge) create the session and settle on `checkout.session.completed`; `stripe-webhook` verifies the signature. **Purely code: no live Stripe account, keys or webhook endpoint are configured, and no payment has ever been run.** |
| Communities (servers) | `00023`: categories, text/voice/forum channels, bitmask roles, per-channel overwrites, invites, bans, voice presence — tested. |
| Broadcast channels | One-voice-many-readers channels with post policies and subscriber counts (`createBroadcastChannel`, `channel_join`) — tested at the SQL level. |
| Bot platform | `00026`: bots, slash commands with platform builtins (`/mute`, `/ban`, `/purge`, …), automated keyword moderation, scheduled broadcasts, inline queries, signed webhooks, and the **@BotFather** master bot in the Messages tab. `bot-api` is a single Edge endpoint that speaks both the Discord (`sendMessage`, roles, moderation) and Telegram (`getUpdates`, inline) shapes — tested. |

### The messenger (pre-existing, still true)

| Capability | Honest status |
| --- | --- |
| Direct/group chats, media, typing, receipts | Implemented; server policies and bridge flows have automated tests. |
| Messaging pro (`00024`) | Reactions, pins, polls, folders, saved messages, scheduled sends, TTL expiry, forwarding, search — tested. |
| Web client / PWA | Flutter web release compiles in CI at site root `/`. Intended Vercel Hobby URL is `https://officialmessengerx.vercel.app` — **not serving a deployment** (`DEPLOYMENT_NOT_FOUND` on 25 September 2026). |
| Google sign-in | Client flow exists; requires hosted Google OAuth and Supabase configuration. No account-age check: Google does not prove account age. |
| Standalone Telegram identity | Gated `custom:telegram` OIDC option (Telegram-app approval). Needs a real BotFather client, hosted provider and live verification before enabling. **Not the requested in-app phone/code identity sign-in.** |
| TDLib phone/code/2FA connection | Exists **after** MessengerX sign-in. Requires a durable worker, a real Telegram API ID/hash and encrypted persistent session storage. |
| Chat with Telegram users | Existing mirrors open in-app; starting a new private conversation by an exact public `@username` has an owner-scoped worker queue and simulated tests. No phone-number search or contact import. |
| Notifications | Three paths, none of them FCM/APNs: browser push (`00017`, needs no worker), the user's own Telegram Saved Messages (needs the TDLib worker), and local banners while the app is open. Browser push needs VAPID secrets and a real device test. |
| Android/iOS binaries | Native project sources, OAuth callbacks, permissions and icons are tracked; CI checks a placeholder-config Android **debug** build. No signed release or device test. iOS PWA is the $0 install path. |
| Hosted database, public site, native worker | **Not provisioned.** SQL/RLS tests are not proof of live security, backup or uptime. |

### Not done (and not pretended otherwise)

* No transcoding pipeline: MP4 only, uploads capped at 250 MB in the client and
  1 GiB / 4 h for long form on the server.
* No FCM/APNs: notifications ride browser push and Telegram, as above.
* No live payments, no live B2 bucket, no deployed edge functions in this repo.
* No device or integration test of the rewritten Flutter UI, the voice-over
  path, or the new store/community/bot screens.
* No CDN, no DRM, no recommendations beyond the SQL ranking functions.

## Map of the repository

```text
apps/mobile_app/            Flutter client: feeds, reels, player, composer, communities, bots, store, settings
apps/mobile_app/web/push/   Web Push client + service worker (the $0 no-worker alerts)
supabase/migrations/        SQL schema, RLS, RPCs, storage policies and queues (00001–00031)
supabase/functions/         Deno edge functions: video-ticket, stripe-*, bot-api, telegram-*, web-push-send
services/telegram_bridge/   TDLib worker, simulated transport and tests
infra/                      Optional worker process/container examples (not a host)
tools/sql-test/             PGlite migration, RLS and contract tests (168 checks)
tools/functions-test/       Edge-function tests (54 checks) and Deno typechecking
docs/runbook.md             Local checks, deployment checklist and launch blockers
docs/architecture.md        Trust boundaries
```

### Migrations

| Range | What it adds |
| --- | --- |
| `00001`–`00019` | Accounts, access state, chats, messages, media, push, Telegram bridge. |
| `00020` | Social graph: follows, private requests, blocks, profile directory. |
| `00021` | Video platform: categories, videos, chapters, sounds, comments, views, playlists, notifications. |
| `00022` | Shorts: reels, sounds feed, shares/saves, duet/stitch. |
| `00023` | Communities: servers, categories, channels, roles, overwrites, invites, voice, broadcast channels. |
| `00024` | Messaging pro: reactions, pins, polls, folders, saved, scheduling, TTL. |
| `00025` | Stars, custom tags, cosmetics, payments, payouts, refunds. |
| `00026` | Bots: bots, commands, installs, rules, broadcasts, inline, webhooks, @BotFather. |
| `00027` | Refunds for settled Stripe payments. |
| `00028` | Client surface: the RPCs the rewritten app reads (search, creator stats, trending hashtags, channel/community/bot directories, broadcast channels). |
| `00029` | Media visibility for the storage ticket. |
| `00030` | `short_detail` for a shared reel link. |
| `00031` | `author_videos` for a channel page. |

## Verify the code

```bash
npm ci
npm run check           # typecheck + SQL/RLS, seed, edge config, functions and bridge tests
bash tools/verify-client.sh   # requires a local Flutter SDK; analyze, test, release web build
```

The [CI workflow](.github/workflows/ci.yml) runs the Flutter analyze/test/web
build and an Android debug compile check. A green CI run cannot verify real
OAuth, Supabase RLS on hosted Postgres, Stripe, Backblaze, Telegram's MTProto
servers, Android/iOS device permissions, or a running worker.

## $0 constraints

Vercel Hobby can host the static website (see [docs/vercel.md](docs/vercel.md))
and Supabase Free can host the database within quotas; the Free database can
pause when unused. Browser notifications are the one alert path with no
always-on requirement. Neither Vercel, short-lived functions nor a sleeping free
instance is a durable TDLib user-session worker, so chatting with real Telegram
users and offline Saved Messages notices must not be advertised as live until
that worker has been provisioned and tested. No signed public Android installer
exists; the $0 iPhone option is the PWA, not an App Store app. Standalone in-app
phone/code identity sign-in is not implemented.

## Secrets

Never put a service-role key, bridge token, BotFather secret, Stripe secret,
B2/S3 key, TDLib session or Google client secret in Flutter, a web build,
repository variables or a Git commit. A Supabase publishable/anon key is public
by design; RLS must still be tested.

## License

MIT.
