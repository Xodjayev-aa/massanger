# Deploy MessengerX on Vercel Hobby (site root)

**Updated 26 September 2026. This file is a checklist, not a live launch.**
The chosen free address is `https://officialmessengerx.vercel.app`, confirmed by
the owner. Earlier revisions of this repository hard-coded a *different* name
(`messengerx-uz.vercel.app`) and the build script refuses to compile for any host
it was not told about — so the owner's real project could not build at all, which
is why that host answered HTTP 500. This revision makes
`officialmessengerx.vercel.app` the chosen host. GitHub Pages at
`https://xodjayev-aa.github.io/massanger/` returns 404 and is no longer the
deployment path. Nothing in this repository has been applied to a hosted
Supabase project from here. Do not paste secrets into chat, Git, or a GitHub
issue.

Budget stays **$0**. Use Vercel Hobby and Supabase Free. Do not add a card, do
not pick Oracle, and do not leave a personal computer on as the worker.

Vercel hosts the **static website only**. It is not a persistent TDLib worker.
Chatting with real Telegram users, and offline notices in your own Saved
Messages, still need a durable worker with encrypted persistent storage. No
such $0 host is provisioned. Standalone in-app phone/code identity sign-in is
not implemented. There is no signed public Android installer. The $0 iPhone
install is **Add to Home Screen** (the PWA), not an App Store app.

## 0. Chosen hostname

`https://officialmessengerx.vercel.app` — the owner's Vercel project, and the
value compiled into `INTENDED_SITE_HOST` / `INTENDED_REDIRECT_URL` in
`apps/mobile_app/tool/web_build_config.mjs`.

If you ever rename the Vercel project, the web build **fails on purpose** rather
than compiling an OAuth return URL that no longer matches:

```
Refusing to build for "<new-host>". The chosen free hostname is officialmessengerx.vercel.app.
```

That guard is deliberate — a mismatch here means sign-in silently returns to the
wrong origin. To move to a new host, change the constants and the documentation
together (the test suite asserts they agree), or set
`MESSENGERX_ACCEPT_SITE_HOST` to the explicitly agreed name for a one-off build.

The build compiles the OAuth return URL as `https://officialmessengerx.vercel.app/`
(site root, no `/massanger/` path).

## 1. What you type where (do not mix these up)

| Place | Field | Value | What it is not |
| --- | --- | --- | --- |
| Vercel → Environment Variables | `SUPABASE_URL` | `https://<project-ref>.supabase.co` | Not the service-role key. Not the database password. |
| Vercel → Environment Variables | `SUPABASE_ANON_KEY` | Public **anon** JWT or **publishable** key (`sb_publishable_…`) | Not `service_role`, not `sb_secret_…`. |
| Supabase → Authentication → URL Configuration | Site URL | `https://officialmessengerx.vercel.app` | Not the Supabase project URL. Not the old GitHub Pages URL. |
| Supabase → Redirect URLs | allowlist | the three Vercel entries in §4 | Not Google's callback. |
| Supabase → Edge Function secrets | `ALLOWED_ORIGINS` | `https://officialmessengerx.vercel.app` | An **origin**: https, no path, no trailing slash, never `*`. |
| Google Cloud → OAuth client → Authorized JavaScript origins | origin | `https://officialmessengerx.vercel.app` | No path, no trailing slash. This replaces a Pages origin if one was saved. |
| Google Cloud → OAuth client → Authorized redirect URIs | callback | `https://<project-ref>.supabase.co/auth/v1/callback` | **Leave this as Supabase.** Do not replace it with the Vercel address. |

Why Google is split that way: the browser page lives on Vercel, so Google's
**JavaScript origin** is the Vercel origin. Google does not send the login
code to Vercel. Supabase is the OAuth client, so Google's **redirect URI**
stays Supabase's `/auth/v1/callback`. Supabase then sends the browser back to
the Vercel site, which is why the Supabase Site URL and Redirect URLs must be
the Vercel address. Putting the Vercel URL in Google's redirect URI breaks
sign-in (`redirect_uri_mismatch` or a code the app cannot exchange). Putting
the Supabase callback in the JavaScript-origin box is also wrong.

The anon/publishable key is public by design and will be inside the website
JavaScript. That is expected. The service-role key, Google client secret,
Telegram API hash, `SEAL_KEY`, `BRIDGE_TOKEN` and `BRIDGE_HMAC_SECRET` must
never be Vercel variables. The build fails if those names are set, so a
mistake does not get compiled into the site. Do not paste any of them here.

## 2. Connect Vercel Hobby

1. Sign in at [vercel.com](https://vercel.com) with GitHub. Stay on **Hobby**.
   If Vercel asks you to upgrade or add a card to import this public repo,
   stop. Do not pay.
2. **Add New… → Project** and import `Xodjayev-aa/massanger`.
3. **Project Name:** `officialmessengerx`. If the name is taken, stop and ask.
4. **Framework Preset:** Other.
5. **Root Directory:** `apps/mobile_app` (recommended). The repository root
   also works: root `vercel.json` calls the same script and publishes
   `apps/mobile_app/build/web`. Pick one and leave it.
6. Confirm the import screen matches the committed file. For Root Directory
   `apps/mobile_app`:
   - Install Command: `bash tool/vercel_build.sh install`
   - Build Command: `bash tool/vercel_build.sh build`
   - Output Directory: `build/web`
   Do not replace these with `npm run build` or `flutter build web`. Vercel
   does not install Flutter unless this script runs. The script downloads
   Flutter **3.24.5** (the same version as CI) because the build image does
   not include it. The first build can take 10–20 minutes and must finish
   inside Hobby's 45-minute limit.
7. **Environment Variables** for Production (and Preview, if you want preview
   builds to compile). Type them in Vercel's form. Do not paste them into chat.
   - `SUPABASE_URL` = Project Settings → API → Project URL
   - `SUPABASE_ANON_KEY` = Project Settings → API → `anon` `public`, or the
     publishable key. You may instead set `SUPABASE_PUBLISHABLE_KEY` to that
     same public value. Do not set both to different values.
   - Leave `TELEGRAM_OIDC_ENABLED` unset or set it to `false`. Set `true`
     only after the hosted Telegram OIDC smoke test in
     [telegram-sign-in.md](telegram-sign-in.md).
   - Do not add any secret from the forbidden list in §1.
8. Deploy. Production branch must stay **`main`**. This session's branch is
   not `main`. Merging the pull request does not by itself create the Vercel
   project. After the project exists and the pull request is merged, a push
   to `main` is what Vercel builds for `https://officialmessengerx.vercel.app`.
9. Changing an environment variable does **not** change an already built
   Flutter bundle. Use **Deployments → Redeploy** after saving variables.
10. Open `https://officialmessengerx.vercel.app/`. It is live only if you see the
    MessengerX sign-in page, not `DEPLOYMENT_NOT_FOUND`. A build that used
    placeholder keys shows "MessengerX cannot start" instead of signing in.
    That is a failed configuration, not a launch.

Google sign-in from a **preview** URL still returns to the production origin
above, and only after that origin is allowlisted. Test sign-in on the
production URL.

## 3. Reload, PWA, and Google sign-in checks

After a real production deploy (not before):

1. Reload these URLs. Each must return the app's HTML (the sign-in page or a
   loading spinner), **not** Vercel's "This page doesn't exist" / `404:
   NOT_FOUND`:
   - `https://officialmessengerx.vercel.app/`
   - `https://officialmessengerx.vercel.app/sign-in`
   - `https://officialmessengerx.vercel.app/chats`
   - `https://officialmessengerx.vercel.app/chats/00000000-0000-4000-8000-000000000000`
   The last URL will not open a real chat until you are signed in. It must
   still be the Flutter app. The rewrite in `vercel.json` sends unknown paths
   to `index.html` after real files (JavaScript, icons, the service worker)
   are served as themselves. The web build uses path URLs, not `/#/chats`.
2. **PWA, desktop Chrome:** open the production URL → install icon in the
   address bar, or menu → **Install MessengerX**. DevTools → Application →
   Manifest should show MessengerX, scope `/`, and 192/512 icons. Application
   → Service Workers should list `flutter_service_worker.js`. If the install
   icon never appears, the service worker or manifest failed; do not claim
   the PWA is installable.
3. **iPhone ($0):** Safari → Share → **Add to Home Screen**. That is the free
   install. It is not an App Store app, it does not add APNs, and it is not
   an offline copy of your chats. Android has **no signed public installer**
   in this repo. A debug APK from CI is not a release.
4. **Google sign-in:** only after §4 and §5, in a private window, on the
   production URL, tap **Continue with Google**. You should land back on
   `https://officialmessengerx.vercel.app/` signed in. If Google says
   `redirect_uri_mismatch`, you changed Google's redirect URI; put back
   `https://<project-ref>.supabase.co/auth/v1/callback`. If Supabase says the
   redirect URL is not allowed, add the three Vercel redirect entries in §4.
   Do not paste tokens or the full error URL into chat (it can contain a
   one-time code).

This repository cannot perform those live checks without your Vercel and
Supabase dashboards. Do not treat a green CI run as a live site.

## 4. Supabase URL configuration

In the Supabase dashboard for **your** project (Authentication → URL
Configuration):

1. **Site URL:** `https://officialmessengerx.vercel.app`
2. **Redirect URLs**, add each of these, then remove
   `https://xodjayev-aa.github.io/massanger/` and any `/**` variant of it if
   it is still listed:
   - `https://officialmessengerx.vercel.app`
   - `https://officialmessengerx.vercel.app/`
   - `https://officialmessengerx.vercel.app/**`
3. Save.
4. Add `com.messengerx.app://login-callback` **only** after you have installed
   a native build you actually tested. There is no signed public Android
   installer yet, so leave the native callback off until then.
5. Avoid wildcard hosts (`https://*.vercel.app/**`). Preview URLs are not the
   production sign-in target.

`supabase/config.toml` `site_url` is the **local** Docker stack
(`http://localhost:5050`). Do not copy it to production, and do not point
local development at the Vercel site.

Authentication → Providers → Google: enable the web client with scopes
`openid`, `email`, `profile` only. No Gmail or Drive scope. Copy the callback
Supabase displays — it is `https://<project-ref>.supabase.co/auth/v1/callback`
— into Google, as §5 describes. The client secret stays in Supabase Auth.
Never put it in Vercel or Flutter.

## 5. Google Cloud OAuth client

1. Open [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials).
2. Open the **OAuth 2.0 Client ID** of type **Web application** that Supabase
   uses. If you do not have one, create a Web application client. Do not
   create an Android or iOS client for this website.
3. **Authorized JavaScript origins:** add `https://officialmessengerx.vercel.app`.
   Remove `https://xodjayev-aa.github.io` if it is there. No path, no
   trailing slash.
4. **Authorized redirect URIs:** keep
   `https://<project-ref>.supabase.co/auth/v1/callback`.
   Do **not** delete it. Do **not** replace it with the Vercel URL. A
   localhost callback is fine for local Supabase only.
5. Save. OAuth consent screen, if Google asks: external, app name MessengerX,
   scopes limited to openid/email/profile. Google does not prove account age.

## 6. Edge Function CORS origin

Hosted functions run with `MESSENGERX_ENV=production`. Production refuses
`ALLOWED_ORIGINS=*` and refuses a path or a trailing slash.

Set the secret in either place (the value is a public origin, but still type
it in the dashboard or CLI on your machine — do not paste other secrets):

- Dashboard → **Edge Functions → Secrets** (some projects show this under
  Project Settings → Edge Functions), or
- On your computer, after `supabase link` (see §7):

```bash
supabase secrets set ALLOWED_ORIGINS='https://officialmessengerx.vercel.app'
```

Also set these **before** the functions are reachable, generating the values
on your machine and storing them in a password manager. Use the same three
values later on the worker, and nowhere else. Do not paste them into chat.

```bash
openssl rand -hex 32
openssl rand -base64 32
openssl rand -base64 32
```

- `SEAL_KEY` = the 64 hex characters from the first command (32 bytes).
- `BRIDGE_TOKEN` = the second value (at least 32 characters).
- `BRIDGE_HMAC_SECRET` = the third value, different from the token.

Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` into the function runtime. You do not copy the
service-role key into GitHub or Vercel.

`ALLOWED_ORIGINS` is the scheme and host only. `https://officialmessengerx.vercel.app/`
with a slash will fail the production check. `https://xodjayev-aa.github.io`
is the wrong origin for this deploy.

## 7. Migrations and Edge Functions, without resetting production

**This workspace did not link your project, did not run `db push`, and did
not deploy functions.** Do that on your own computer when you are ready.
Ask before anyone else runs it. Never run `supabase db reset` or
`supabase db reset --linked` against the hosted project: reset drops data.
`make db-reset` is local Docker only. `make deploy` now refuses to run unless
you set `MESSENGERX_CONFIRM_HOSTED_PUSH=yes` after reading this section.

The hosted project previously had **no migrations applied**. Pushing applies
`supabase/migrations/00001` through `00017` in order. It does not import
`supabase/seed.sql`. Do not load seed data into the hosted project.

1. Install the [Supabase CLI](https://supabase.com/docs/guides/cli) on your
   computer. `supabase login` opens a browser. Do not paste the access token
   into chat.
2. In the dashboard URL `https://supabase.com/dashboard/project/<project-ref>`,
   copy the ref. From this repository:

   ```bash
   supabase link --project-ref <project-ref>
   ```

   The CLI asks for the database password. Type it locally. Do not send it here.
3. **Backup first.** Supabase Free does not include a managed daily backup you
   can rely on. In the dashboard open **Database → Backups**. If download is
   unavailable on Free, dump from your computer before changing anything:

   ```bash
   supabase db dump --linked -f messengerx-backup.sql
   ```

   Keep that file private. It is not a substitute for a tested restore, but
   it is the $0 export. Storage objects are not inside the SQL dump; this
   project previously had no live site, so expect little or no user data, and
   still dump before the first push. Do not commit the dump.
4. See what would change. This does not write:

   ```bash
   supabase db push --dry-run
   ```

   Read the list. It should be the repository migrations only, not a reset.
   If the dry-run wants to drop tables, stop.
5. Apply pending migrations only:

   ```bash
   supabase db push
   ```

   If the CLI has no `--dry-run` in your version, stop and upgrade the CLI
   rather than guessing. Do not run `make db-reset`.
6. **RLS check** in the dashboard SQL editor (read-only; it changes nothing):

   ```sql
   select c.relname as table_name, c.relrowsecurity as rls_enabled
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
   order by c.relname;
   ```

   `rls_enabled` must be true for the app tables, including `profiles`,
   `chats`, `messages`, `telegram_accounts`, `telegram_link_requests`,
   `telegram_outbox`, `telegram_inbox_events`, `google_credentials`,
   `notify_requests`, `chat_typing` and `telegram_chat_requests`. Then:

   ```sql
   select tablename, policyname, roles, cmd
   from pg_policies
   where schemaname = 'public'
   order by tablename, policyname;
   ```

   `notify_requests`, `telegram_chat_requests`, `telegram_inbox_events` and
   `google_credentials` must not be readable by another signed-in user.
   After two real accounts exist, sign in as one and confirm the other
   person's private chat, Telegram queue and media path are not visible.
   A PGlite test in CI is not this check.
7. Deploy functions from this repository so `supabase/config.toml` JWT flags
   are what the CLI uploads:

   ```bash
   supabase functions deploy telegram-link
   supabase functions deploy telegram-send
   supabase functions deploy telegram-ingest
   supabase functions deploy account-age-gate
   supabase functions deploy web-push-send --no-verify-jwt
   ```

   Then in the dashboard confirm:
   - `telegram-link`, `telegram-send`, `account-age-gate`: **Enforce JWT on**
   - `telegram-ingest`: platform JWT **off**, because the worker has no user
     JWT. The function still requires the private bridge bearer **and** HMAC.
     Never turn that application check off, and never put those credentials
     in the Flutter app.
   - `web-push-send`: platform JWT **off** as well, because its scheduled caller (a
     database webhook or `pg_cron`) has no session either. Both of its entry
     points authenticate themselves: a Supabase session for a sender's tab, or
     `WEB_PUSH_SWEEP_TOKEN` for the scheduled sweep. It is optional — with no
     VAPID secrets it reports the feature as unconfigured and nothing else
     changes. Setup is in [runbook §5b](runbook.md#5b-browser-notifications-0-no-worker).
8. Set `MESSENGERX_ENV=production` if the hosted runtime does not already
   force it. The function code treats a missing value as production and
   refuses to boot without `SEAL_KEY`, `BRIDGE_TOKEN`, `BRIDGE_HMAC_SECRET`
   and an exact HTTPS `ALLOWED_ORIGINS`.

`make deploy` runs the same push and the four deploys, and only after
`MESSENGERX_CONFIRM_HOSTED_PUSH=yes`. Prefer the commands above so you can
stop between the dry-run, the backup, and the push.

## 8. What will still not work after the website is up

- **Real Telegram chats** and **offline Saved Messages notices** need the
  TDLib worker in `services/telegram_bridge/` running continuously with a
  persistent encrypted data directory. Vercel cannot do that. A free sleeping
  host cannot do that. No Oracle account and no always-on personal computer
  are part of this plan. Until that worker exists and is tested, linking will
  not finish and those features must not be described as live.
- **Phone/code identity sign-in** (an account created inside the app without
  Google or Telegram OIDC) is not implemented. The phone → code → optional
  2FA screen only links TDLib after a MessengerX sign-in, and only if the
  worker is actually running.
- **Android:** no signed public installer. **iPhone:** PWA only on this budget.
- Supabase Free can pause after inactivity. A paused database makes the
  website look signed-out or failed even when Vercel is up. That is a quota
  limit, not a second copy of the app.
