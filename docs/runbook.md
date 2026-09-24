# MessengerX runbook

Operational truth for this repository: how to get it running, what has to be
provisioned outside the repo, and what to do when Telegram stops syncing.

Numbers quoted here are asserted by the local test suites: 79 schema behaviours
(`tools/sql-test/run.mjs`), 8 seed checks (`tools/sql-test/seed-check.mjs`),
102 bridge behaviours (`services/telegram_bridge/test/*.test.ts`). The Flutter SDK
is required separately to run its analyzer/tests.

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
| `websocket` | WebSocket transport (`TD_WS_URL`); requires your own verified adapter | optional only; no sidecar image is bundled or tested here |

The suite (`npm run test:bridge`) exercises the protocol **contract** against
`memory`, which is the only honest way to test `updateAuthorizationState`,
`sending_id` echo correlation and `FLOOD_WAIT_n` parking without talking to
Telegram's servers. The real `koffi` path **still needs** a TDLib build and a
real-account/phone verification — §5 ends with that checklist. The optional
`websocket` adapter is not part of the Oracle deployment and is unverified here. GramJS is deliberately **not** an adapter:
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
`telegram-ingest`), twelve migrations, one long-lived Node worker per shard, and the
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
| | `MESSENGERX_ENV=production` | the worker defaults to `development`; the functions do not |
| `supabase/functions/.env.local` | `BRIDGE_BASE_URL` | `http://host.docker.internal:8787` — a function in Docker cannot reach the worker's `localhost`, and the bridge itself does not read this key |
| `.messengerx/app.json` | `SUPABASE_URL`, `SUPABASE_ANON_KEY` | API URL + anon key |

Migrations and `seed.sql` are applied by `supabase start` (and by
`supabase db reset`, which is the check CI runs against PGlite):

```bash
make db-reset        # replay 00001..00012 then seed.sql
npm run check        # 79 SQL + 8 seed + 102 bridge assertions + both typechecks
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
  ALLOWED_ORIGINS=https://<ref>.supabase.co,io.messengerx.app,com.messengerx.app
# Do NOT set BRIDGE_BASE_URL on the $0 VM path: Realtime + the 3-second poll
# deliver work without exposing the worker or buying a domain/certificate.
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

### 4.1 Worker on Oracle Cloud Always Free — $0 path

**Deployment status:** this is a reproducible recipe, not an already provisioned VM.
An Oracle tenancy, a hosted Supabase project, Telegram API credentials and the
Google OAuth configuration above still have to be created by the operator. The
worker must run all day and keep TDLib's SQLite session files on persistent
storage; a sleeping free web host cannot do this job.

As of June 2026, [Oracle's Always Free resource list](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
allows the equivalent of **2 Ampere A1 OCPUs + 12 GB RAM**, with **200 GB combined
boot/block volume** in the tenancy's *home region*. Labels and limits can change:
select only **Always Free-eligible** resources, check the cost estimate before
launching, and set a billing alert. The A1 shape may be temporarily unavailable;
Oracle may reclaim an instance it considers idle over seven days. **$0 is a budget,
not an uptime guarantee.** The free tier may require payment-card verification.

1. Create an **Ubuntu 22.04/24.04 ARM64** `VM.Standard.A1.Flex` in your home region,
   1 OCPU/6 GB for a small test account (expand within the current free allowance
   if needed). Keep its default persistent boot volume (counts toward the free
   200 GB total); assign an outbound-capable public IP. Open **only SSH from your
   own IP** in the OCI security list and the VM firewall. There is no inbound
   application port: the worker connects *out* to Telegram and Supabase.
2. Install Node 22 (the repo requires ≥20.11; the current Supabase SDK needs 22),
   Git, CMake, OpenSSL headers and a compiler. On Ubuntu, for example:

   ```bash
   sudo apt-get update
   sudo apt-get install -y git curl ca-certificates cmake build-essential libssl-dev zlib1g-dev
   # Review the vendor install script before running it as root, or use an
   # equivalent trusted Node 22 package for your distribution.
   curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
   sudo apt-get install -y nodejs
   node --version
   ```

3. Build the same pinned TDLib JSON library as the bridge image. Upstream has
   **no `v1.8.43` Git tag**: pin its actual 1.8.43 commit instead. TDLib's CMake
   install does **not** define a `lib` component; disable static installs and
   install normally. Building on one OCPU may take a while; use one compiler job
   on a 6 GB VM to avoid running out of memory.

   ```bash
   TDLIB_COMMIT=11406d9d6f3baa999b77fbd09f36c67749c31699
   git init /tmp/td
   git -C /tmp/td remote add origin https://github.com/tdlib/td.git
   git -C /tmp/td fetch --depth 1 origin "$TDLIB_COMMIT"
   git -C /tmp/td checkout --detach FETCH_HEAD
   cmake -S /tmp/td -B /tmp/td/build -DCMAKE_BUILD_TYPE=Release \
     -DTD_INSTALL_STATIC_LIBRARIES=OFF -DBUILD_TESTING=OFF
   cmake --build /tmp/td/build --target tdjson -j 1
   sudo cmake --install /tmp/td/build
   sudo ldconfig
   ldconfig -p | grep libtdjson
   ```

4. Install **the reviewed remote revision that contains migration 00012 and this
   unit**, not an older `main`. The next developer first pushes the session branch
   `arena/01a0d3aa-massanger` after review; set `DEPLOY_REF` to that branch, or
   to a reviewed release ref once merged. Keep source readable and session files
   writable by a dedicated user:

   ```bash
   DEPLOY_REF=arena/01a0d3aa-massanger  # only after this branch has been pushed
   sudo useradd --system --home /var/lib/messengerx-bridge --shell /usr/sbin/nologin messengerx
   sudo install -d -o messengerx -g messengerx -m 0755 /opt/messengerx
   sudo -u messengerx git clone --branch "$DEPLOY_REF" --single-branch \
     https://github.com/Xodjayev-aa/massanger.git /opt/messengerx
   cd /opt/messengerx
   sudo -u messengerx npm ci
   sudo -u messengerx npm run build:bridge
   ```

5. Install the **native** systemd unit already in this repo (no container on this
   path). The service name is `messengerx-bridge`, **not** `massanger-bridge`.
   Install it from the checked-out revision, create a private environment file
   *without truncating any existing secrets*, and edit it on the VM. The unit's
   `ExecStart` assumes NodeSource installed Node at `/usr/bin/node`; check
   `command -v node` and adjust that path in the unit **before installing** if
   your distribution differs:

   ```bash
   sudo install -D -o root -g root -m 0644 infra/messengerx-bridge.service \
     /etc/systemd/system/messengerx-bridge.service
   sudo install -d -o root -g root -m 0700 /etc/messengerx
   if ! sudo test -e /etc/messengerx/bridge.env; then
     sudo install -o root -g root -m 0600 /dev/null /etc/messengerx/bridge.env
   fi
   sudoedit /etc/messengerx/bridge.env
   sudo chown root:root /etc/messengerx/bridge.env
   sudo chmod 0600 /etc/messengerx/bridge.env
   ```

   Populate `/etc/messengerx/bridge.env` with **real** values (the placeholders
   below must be replaced, not copied literally):

   ```ini
   SUPABASE_URL=https://YOUR-PROJECT.supabase.co
   SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
   TELEGRAM_API_ID=YOUR_API_ID
   TELEGRAM_API_HASH=YOUR_32_HEX_CHARACTER_API_HASH
   SEAL_KEY=YOUR_SHARED_64_HEX_CHARACTER_KEY
   BRIDGE_TOKEN=YOUR_SHARED_BRIDGE_TOKEN
   BRIDGE_HMAC_SECRET=YOUR_SHARED_HMAC_SECRET
   TDLIB_DB_KEY=YOUR_ONCE_GENERATED_BASE64_32_BYTE_KEY
   BRIDGE_WORKER_ID=oracle-free-1
   BRIDGE_MAX_SESSIONS=4
   TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so
   BRIDGE_HEALTH_PORT=8787
   ```

   `SEAL_KEY`, `BRIDGE_TOKEN` and `BRIDGE_HMAC_SECRET` must match the hosted
   functions (§4); `TDLIB_DB_KEY` must be generated **once** (e.g. `openssl rand
   -base64 32`) and kept with the session backup. The unit defaults to
   `MESSENGERX_ENV=production`, `BRIDGE_TRANSPORT=koffi`,
   `BRIDGE_DATA_DIR=/var/lib/messengerx-bridge` and
   `BRIDGE_HEALTH_HOST=127.0.0.1`; do not override those with less secure
   values in the env file. Do **not** put secrets in Git, the unit or shell
   history. The unit's `StateDirectory=messengerx-bridge`, `StateDirectoryMode=0700`
   and `UMask=0077` keep TDLib state on the VM's persistent boot volume and
   private to the service user. Keep **both** the directory and encryption key
   across restarts/upgrades; losing either makes linked users reauthenticate.
   Never run two workers against the same TDLib session directory.

   `infra/docker-compose.yml` is a **separate optional** container deployment
   with its own named volume; it is not a prerequisite for this systemd service.
   Do not start Compose and systemd together against the same linked account.
   Outbound HTTPS to Supabase/Telegram is needed, but inbound ports **80/443 are
   not**: the worker uses polling/Realtime, and its admin listener stays on
   loopback. Restrict inbound SSH to your IP in OCI and the host firewall.

6. Apply 00012 to hosted Supabase (`supabase db push`, §4), deploy the functions,
   then start the worker and verify it locally on the VM:

   ```bash
   sudo systemd-analyze verify /etc/systemd/system/messengerx-bridge.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now messengerx-bridge
   sudo systemctl status messengerx-bridge
   journalctl -u messengerx-bridge -n 80 --no-pager
   curl -fsS http://127.0.0.1:8787/healthz
   curl -fsS http://127.0.0.1:8787/readyz
   # Later upgrades: git pull; npm ci; npm run build:bridge; systemctl restart.
   ```

`BRIDGE_BASE_URL` is **unset** (run `supabase secrets unset BRIDGE_BASE_URL` if
an earlier deploy configured it): Supabase Edge Functions do not need to call this VM.
The worker uses Supabase Realtime for fast wakes (including `notify_requests`) and a
3-second poll as the safety path. The admin port stays on loopback, so no paid
hostname, load balancer, cert or open port 8787 is necessary. If Realtime drops,
the poll still claims work. For an *optional* public wake endpoint, first arrange a
free subdomain and HTTPS plus the bearer/HMAC authentication; exposing
`/internal/wake` directly over plaintext HTTP is not the $0 shortcut to take.

**Free hostname boundary:** Supabase gives the API `*.supabase.co`; a future
web-compatible frontend can live at `*.pages.dev` / `*.github.io` without buying
a domain (do not assume the current Flutter app's `dart:io` media paths build for
web without adaptation). This worker needs no hostname at all. Google OAuth **Testing** (≤100 testers) is a development path,
but publishing an external app with restricted Gmail scopes may require a verified
site/domain, a privacy policy and Google's verification; a borrowed subdomain may
not satisfy that, so do not promise unlimited public sign-ups for $0. The notices
use *Telegram's* installed app on iOS — **Apple Developer membership (~$99/year)**
is still needed for App Store distribution or native APNs; a domain is not the APNs
fee. Nothing in this recipe signs or distributes an iOS app.

---

## 5. The Telegram bridge

### 5.1 Run it locally

```bash
cd services/telegram_bridge
cp .env.example .env          # or `make env` from the repo root
# Replace placeholders: .env is ignored by Git, and Node 22 loads it explicitly.
BRIDGE_TRANSPORT=memory npm run dev
```

`npm run dev` uses `node --env-file=.env`; `make bridge` sets the memory
transport the same way. Fill in a reachable Supabase URL/service-role key (and
function secrets if using the ingest function): copying placeholders is not a
working server configuration. With `memory` the worker starts a fake Telegram
core: linking, code entry, sending, read receipts and FLOOD_WAIT parking behave
as they do against the real thing, and `SIM_PHONE_CODE` accepts a fixed code so
you can walk the whole flow without a phone:

```
GET  /healthz  → {"ok":true,"transport":"memory",…}
GET  /readyz   → 200 while the manager is running
GET  /metrics  → Prometheus text, prefix messengerx_bridge_*
POST /internal/wake  {"kind":"outbox","user_ids":["<uuid>"]}   # Bearer + HMAC
```

`/internal/wake` is an **optional** latency hint from `telegram-send` after
inserting an outbox row; Realtime and the default 3000 ms poll make it unnecessary
on the $0 VM path (§4.1). Bodies over
64 KiB are refused with 413 — a wake payload is tiny on purpose. Any other path
returns 404 with no hint of what exists.

### 5.2 Real TDLib, against your own account

**Handoff gate (a workstation with Flutter and physical phones):** first review
and push the session branch **on the source checkout** when ready to share:

```bash
git push origin arena/01a0d3aa-massanger
```

On the **test machine** (or use an existing checkout of the same reviewed ref):

```bash
git clone --branch arena/01a0d3aa-massanger --single-branch \
  https://github.com/Xodjayev-aa/massanger.git
cd massanger
bash tools/verify-client.sh  # pub get → strict analyze → test; private logs in .messengerx/
```

If the analyzer reports mechanical fixes, apply them **explicitly** and review
source changes before committing:

```bash
bash tools/verify-client.sh --fix  # dart fix + format, then rerun analyze and test
git diff --check && git diff
```

`--fix` is **opt-in**, not a silent formatter pass. Strict analysis can report
informational lints even when CI's `flutter analyze --no-fatal-infos` is green;
resolve meaningful warnings and rerun. Do **not** proceed to the device verdict
on a failed analyzer or test suite. This repository's current environment has
no Flutter SDK; those results must come from the target machine.

Then build/launch the **real** worker with your own Telegram API credentials.
On the Oracle VM, §4.1 builds pinned `libtdjson.so` and the bridge; start it with
`sudo systemctl enable --now messengerx-bridge`. For a *separate local* smoke test
from the repository root, after filling the ignored
`services/telegram_bridge/.env` with real credentials and a **stable**
`TDLIB_DB_KEY` (not a freshly generated key at every restart), use Node 22's
`--env-file` explicitly; the bridge does not auto-load `.env`:

```bash
npm run build:bridge
node --env-file=services/telegram_bridge/.env services/telegram_bridge/dist/main.js
```

Set `BRIDGE_TRANSPORT=koffi`, `TDLIB_LIBRARY_PATH` and all Supabase/Telegram
credentials in that file, with the same `SEAL_KEY` as the edge functions. Get
`TELEGRAM_API_ID`/`TELEGRAM_API_HASH` from <https://my.telegram.org> → API
development tools. Never reuse a bot's app id or put your API hash in Git.

Then in the app: **Telegram → Link account**. Enter your Telegram phone number,
then the code Telegram sends (often to another logged-in Telegram device), then
your 2FA password if you have one. The worker currently supports **phone + code,
not QR login**: TDLib 1.8.43 uses `requestQrCodeAuthentication` and emits a link
in an authorization-state update, not `requestQrCode` or `exportLoginToken`.
Legacy callers that set `useQr` receive a phone-code prompt, not a fake QR. Keep
`BRIDGE_DATA_DIR` across worker restarts; TDLib does not have a JSON login-token
export/import shortcut for stateless failover. With `SEAL_KEY` configured, the
credentials reach the bridge sealed; never link a real account without it.

What to check when you do this for real (the CI suite cannot):

1. `telegram_accounts.auth_state = linked` and `last_inbound_at` advancing within ~3 s
   of a new Telegram message in a synced chat.
2. A message sent from MessengerX appears in Telegram with the same text, and the app
   bubble turns single-tick → double-tick → (after you read it in Telegram) read.
3. `telegram_outbox` for that message reaches `sent`. A row parked because of
   `FLOOD_WAIT_n` shows `next_attempt_at` in the future and retries itself.
4. Reading the chat in *Telegram* clears the MessengerX badge (the reverse of #2).
5. Kill the worker (`^C`) and restart it: sessions are restored from `BRIDGE_DATA_DIR`,
   the link is still valid, and no old Telegram inbound row is duplicated
   (`(chat_id, source, tg_message_id)` is the idempotency key).
6. **Offline notices (00012):** link the *recipient's* Telegram test account
   by phone + code. Use a **second MessengerX user** to send a real message while
   the recipient's MessengerX app has been away for >90 s; the database trigger,
   not a manual `notify_requests` insert, creates the queue row. Allow the
   3-second folding window plus a poll. The recipient should see one
   `MessengerX · sender` text in **their own Saved Messages**. Send two more in
   quick succession; they should fold into one notice with `+N more`. Check
   `notify_requests.state = sent`, `tg_self_chat_id`, `tg_message_id` and the
   bridge's `messengerx_bridge_notices_total` metric. For the separate
   Telegram-mirroring duplicate test, link the sender's Telegram account too:
   a Telegram-origin message already delivered to the recipient must **not**
   add a second notice. Reading, muting for 8 hours, switching push off, or
   reopening the app before the claim must cancel a queued notice; switching
   previews off must render a generic notice and erase queued text. While
   MessengerX is in front, a new non-mirrored message in another unmuted thread
   should show a brief local banner; an open-thread message should not.
7. **iOS OS-alert verdict (not covered by CI):** enable lock-screen alerts for
   the official Telegram app on a real iPhone, disable Focus/Do Not Disturb,
   lock the device and repeat step 6. Confirm **both** the Saved Messages entry
   and an actual lock-screen alert; repeat on Android too. A delivered row is
   *not* proof that an iOS banner appeared: Telegram can suppress notifications
   for self-sent messages. If there is no lock-screen alert, Path A+C does **not**
   meet the background-alert goal on that device; Path C still works *while the
   app is open*. Do not claim native push or automatically switch to Path B:
   APNs/FCM requires a separately approved design, and iOS APNs/App Store
   distribution needs Apple's paid developer program (outside the $0 budget).

### 5.3 Configuration worth knowing

| Variable | Default | Why you would change it |
| --- | --- | --- |
| `BRIDGE_MAX_SESSIONS` | 64 (max 4096) | a worker holds a few hundred TDLib clients comfortably; beyond that, shard by user id |
| `BRIDGE_POLL_INTERVAL_MS` | 3000 | queue fallback — the Realtime wake usually wins; lower costs CPU on the getUpdates loop |
| `BRIDGE_OUTBOX_BATCH_SIZE` | 10 (max 200) | rows claimed per tick; also bounds the offline-notice batch (SQL caps notices at 100) |
| `BRIDGE_OUTBOX_LEASE_SECONDS` | 180 | a crashed worker's lease expires after this; keep it above your worst media upload |
| `BRIDGE_MIN_SEND_INTERVAL_MS` / `BRIDGE_MAX_SEND_PER_MINUTE` | 120 / 20 | Telegram's flood control; the worker parks the row instead of hammering |
| `BRIDGE_SESSION_IDLE_SECONDS` | 600 | idle sessions retire and restart lazily; a notice reopens its recipient's session |
| `push_telegram` / `push_preview` (profile) | true / true | two settings in the Telegram screen: Saved Messages delivery and whether sender/text appear in notices and foreground banners |
| `MESSENGERX_ENV` | `development` | **set it to `production`**: it is what makes the bridge refuse an unsealed link payload and refuse an open admin surface (the functions default to `production`, the worker does not) |
| `TELEGRAM_DEVICE_MODEL` | `MessengerX Bridge` | this is the label in the user's Telegram → Devices list |
| `INGEST_MODE` | `function` | `rpc` posts through the DB directly (service-role) — only for self-hosted installs without edge runtime |
| `TD_VERBOSITY` | 1 | 2 while debugging a link that stalls |
| `BRIDGE_TRANSPORT` | `koffi` | see §0 |

---

## 6. TDLib: version, image, sessions

- **Pin the version.** `services/telegram_bridge/Dockerfile` fetches TDLib's
  *commit* `11406d9d6f3baa999b77fbd09f36c67749c31699` (version 1.8.43).
  There is no upstream `v1.8.43` tag. The JSON API changes across versions, so
  upgrade deliberately: verify the send options against the new `td_api.tl`, bump
  the SHA, build the image, run `npm run test:bridge`, then §5.2's checklist
  against a real account. The memory simulator cannot validate a real TDLib ABI.
- **Building locally** (macOS/Linux): use the fetch + CMake steps in §4.1 with
  `-DTD_INSTALL_STATIC_LIBRARIES=OFF`, then set
  `TDLIB_LIBRARY_PATH=/usr/local/lib/libtdjson.so`. On Apple Silicon add
  `-DCMAKE_OSX_ARCHITECTURES=arm64`; linking an x86 library into an arm64
  process makes `koffi` fail at `dlopen`.
- **Session state** lives in `BRIDGE_DATA_DIR/tg-<user_id>/` — TDLib's own encrypted
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
| `messengerx_bridge_rows_last_tick` stays 0 with queued DB rows | several minutes | DB claim, Supabase key or worker poll failure |
| `messengerx_bridge_parked_total` rises | sustained | Telegram flood wait, missing session, or retryable error (inspect `last_error`) |
| `messengerx_bridge_notices_failed_total` rises | any | a Saved Messages notice exhausted retries or a session was revoked |
| `messengerx_bridge_errors_total` rises | sustained | manager tick/transport failure; inspect JSON logs |
| `GET /readyz` non-200 | 3 consecutive | worker not serving; investigate before a deploy |

`/metrics` exposes totals since the current worker start, not a persisted history.
Check `notify_requests` via a **service-role** SQL session (never the mobile app):

```sql
select state, count(*), min(next_attempt_at) as oldest_due
from public.notify_requests group by state order by state;
select user_id, chat_id, folded, attempts, last_error, next_attempt_at
from public.notify_requests where state in ('queued', 'in_flight')
order by next_attempt_at limit 20;
```

A `queued` notice waiting 3 seconds is healthy (burst folding). A repeatedly
`in_flight` notice beyond the lease suggests a crashed worker or DB completion
problem; the claim RPC reclaims it. Keep preview text and Telegram credentials
out of operator logs.

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
- **Backfill**: there is *no* `sync_direction = backfill` enum value or automated
  historical replay. A lost mapping requires operator review and a separate
  backfill tool; do not set an invalid direction and expect the worker to walk
  history. The live ingest path deduplicates by `(chat_id, source, tg_message_id)`.

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
   stream. The bridge's `notify_requests` subscription uses a service-role JWT;
   that queue intentionally has **no client** SELECT/Realtime policies.
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

## 10. Notifications (A + C), and what is deliberately absent

**A — offline Telegram Saved Messages.** Migration `00012_self_push.sql` adds
`profiles.push_telegram/push_preview`, `telegram_accounts.self_chat_id` and an
internal `notify_requests` queue. For each incoming *non-system* message, the
AFTER trigger checks the recipient's app heartbeat (`last_seen_at` older than 90 s
or null), linked Telegram account, participant mute/leave, and whether a mirrored
Telegram message already buzzed on that person's Telegram. It folds consecutive
messages per `(user_id, chat_id)` into one queued row, refreshed after a 3-second
quiet window. The worker leases with `bridge_claim_notify` and checks
`bridge_notice_owed` again immediately before `sendMessage` to the **recipient's
own Telegram Saved Messages** (not the sender's session). Delivery caches
`self_chat_id`, parks `FLOOD_WAIT_n` for `n+2` seconds, clears a bad chat-id cache,
and stops after four attempts. `mark_chat_read`, muting, leaving, foreground
heartbeats and disabling push cancel queued work; preview-off wipes queued and
leased text. The self chat is never mirrored into MessengerX. Leases make crashes
recoverable but, as with any Telegram send followed by a separate DB write,
**exactly-once delivery across a worker crash cannot be promised**. If the DB
completion fails but the *same* worker stays up, it reuses the TDLib receipt rather
than sending a second copy. Terminal rows are pruned after 3 days by the worker's
6-hour housekeeping loop (`prune_notify_requests`). Clients cannot read the queue.

**C — in-app banners.** `IncomingNotices` subscribes to `messages` INSERT only
while authenticated and foregrounded. It consults the participant read/mute state,
checks whether a Telegram-origin message already arrived on Telegram, fetches the
latest preview preference, skips own/system messages and the open thread, folds a
burst into one 5-second banner and dismisses it when the participant is read or
muted (also across devices). It never schedules an OS notification. A banner
tap **dismisses** it; there is no notice deep-link scheme. The chat list's unread
badge and `chat_feed` are the source of truth on reconnect. The chat list dispatches
a debounced refresh event on participant updates so the new unread state actually
reaches its BLoC listeners. Muting from a chat's header lasts 8 hours and cancels queued offline work in the same DB transaction.

**Limits / decisions:**

- This is **not APNs, FCM or a background Flutter service**. Telegram may not
  generate an OS buzz for self-sent Saved Messages on every client/device; verify
  on real phones (§5.2). Turning on Telegram's notification permission is a
  prerequisite, not a guarantee. Native iOS push/App Store distribution needs
  Apple's paid developer program; it is outside the $0 scope.
- There is **no Telegram Bot API** (it cannot read a personal chat history), and
  **no GramJS adapter** (§0).
- There is **no end-to-end encryption**: TLS + RLS only, and TDLib processes
  media to mirror it. Telegram Saved Messages is stored on Telegram's servers.
- There is **no local offline app message store** (§6). `notify_requests` is a
  *server-side* notice queue, not a way to send messages offline from Flutter.
- There is **no in-app phone sign-in**; the phone number exists only in the
  Telegram link flow.
