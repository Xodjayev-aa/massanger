# Telegram sign-in: independent identity, separate TDLib connection

**Status:** the client contains a *gated* Telegram OIDC sign-in button. It stays
**disabled** unless the operator creates and tests a real `custom:telegram` Supabase
Auth provider and builds with `TELEGRAM_OIDC_ENABLED=true`. This is not a deployed
service or an in-app phone-number/code sign-in.

Telegram OIDC is a $0 identity alternative to Google's login and to Supabase SMS
OTP. A person approves sign-in in Telegram; if they consent to the `phone` scope,
Telegram returns a verified phone claim. It does **not** provide a TDLib session,
read their conversations, or make the bot a user account. To chat as that person,
MessengerX separately runs the existing TDLib phone → code → optional 2FA linking
wizard against a **persistent** worker. Google users can use the same wizard.
Signing in with Google and Telegram independently can produce two MessengerX
accounts; there is no automatic or implicit identity merge.

Official references:
- [Supabase custom OAuth/OIDC providers](https://supabase.com/docs/guides/auth/custom-oauth-providers) (Free: up to three; `email_optional`).
- [Supabase's Telegram OIDC example](https://supabase.com/docs/guides/self-hosting/self-hosted-custom-oauth-providers#example-telegram) (claims, required Auth version, callback).
- [Telegram Login / OIDC](https://core.telegram.org/bots/telegram-login) (PKCE, scope consent, redirect allowlist).

## Provision on a real hosted project (not performed in this repository)

1. Create a Supabase **Free** project and take its HTTPS project URL and public
   publishable/anon key. Apply *all* SQL migrations in order, and deploy the
   edge functions. Never put a service-role key or a Telegram bot secret in
   Flutter/Vercel build variables.
2. Create a Telegram bot in **@BotFather** and enable **Login Widget → OpenID
   Connect Login**. Under allowed URLs, register the exact Supabase Auth callback
   shown on the *Custom OAuth Providers* setup screen, normally
   `https://<project-ref>.supabase.co/auth/v1/callback`. Copy the client ID and
   secret privately to **Supabase Auth**, not to the Flutter app.
3. In Supabase Auth → Providers → **New Provider** → Auto-discovery (OIDC), set:
   identifier `custom:telegram`, issuer `https://oauth.telegram.org`, the BotFather
   client ID/secret, scopes `openid profile phone`, and **Email optional = true**.
   If the dashboard does not expose email-optional or scopes, use Supabase's
   authenticated **admin** custom-provider API from a trusted machine; do not
   call it from Flutter or commit a provisioning script with secrets. Keep PKCE
   enabled and nonce checks on; use the issuer's discovery/JWKS verification.
4. Supabase Auth → URL Configuration: site URL =
   `https://officialmessengerx.vercel.app`, and the redirect allowlist includes that
   origin, the same URL with a trailing slash, and
   `https://officialmessengerx.vercel.app/**`. Add the native callback
   `com.messengerx.app://login-callback` only after a native build has been
   tested. There is no signed public Android installer yet. Google is a
   separate provider with `openid email profile` only (no Gmail/Drive). In
   Google Cloud, the **Authorized JavaScript origin** is the Vercel origin
   `https://officialmessengerx.vercel.app`. Google's **redirect URI** stays
   `https://<project-ref>.supabase.co/auth/v1/callback`. Do not swap those.
   Exact clicks are in [vercel.md](vercel.md).
5. On a test deployment using the **real project**, attempt one new Telegram sign-in
   and one returning sign-in. Verify `auth.users` has the same stable identity,
   the `profiles` trigger created a row with `access_state=active`, `google_email`
   is null, and no bot secret appears in the browser. Test declined phone consent,
   denied approval, token refresh, sign-out, and cross-device sign-in. A placeholder
   CI build is not this test. If the hosted Auth version cannot sign in with a
   provider that has no UserInfo endpoint, leave the button disabled and investigate
   the hosted Auth version; **do not bypass ID token verification**.
6. Only after these live checks, set `TELEGRAM_OIDC_ENABLED=true` in the app's
   *public* build configuration and deploy the website. This flag never
   provisions Auth on its own. Test native deep links independently on devices
   before claiming an Android/iOS build works.

**Privacy:** use the `phone` scope only to obtain the user's own number with
consent; never search Telegram accounts by arbitrary phone number. Do not store
an OIDC `sub` as a TDLib numeric user ID: Telegram's examples show they differ.
The pending TDLib phone/code linking step is the only way the existing bridge
can obtain a user session. Enabling this OIDC option does **not** complete the
requested standalone *in-app phone/code identity sign-in*; that needs a separate,
secure auth-session design, recovery flow, abuse limits and live testing.
