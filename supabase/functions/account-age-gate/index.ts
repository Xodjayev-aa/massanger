/**
 * account-age-gate — "a Google account must be older than one year".
 *
 * Called by the app right after `signInWithOAuth(.google)` (the OAuth access
 * token is still in the session) and again from the Gate screen. It is the
 * *only* writer of `profiles.access_state`, which is what RLS uses to decide
 * whether an account may create chats or send messages at all.
 *
 * Flow
 *   1. verify the caller's JWT (signature locally + live lookup against GoTrue)
 *   2. short-circuit on a fresh cached verdict or a non-Google provider
 *   3. take the access token from the request body (OAuth) or refresh the
 *      sealed refresh token we stored earlier
 *   4. prove the token belongs to *this* user and *this* OAuth client
 *   5. ask Gmail (then Drive) for the oldest timestamp it can prove
 *   6. write the verdict through `record_eligibility_check()` (audit + state in
 *      one transaction) and return it
 *
 * Failure modes are deliberately non-fatal to the account: the default is
 * `restricted`, never a deletion, so a support flow can recover a user whose
 * Google API was having a bad afternoon. `AGE_GATE_ON_FAILURE=delete` exists
 * for operators who want hard rejection.
 */

import { readEnv, sealingAvailable } from '../_shared/env.ts';
import { configureLogger, log, redact } from '../_shared/logger.ts';
import { bearerToken, clientIp, corsHeaders, expectString, ok, readJsonBody, withEnvelope } from '../_shared/http.ts';
import { adminClient, requireUser, rpc, userClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { resolveAccessToken, storeAccessToken } from '../_shared/credentials.ts';
import {
  assertTokenOwnership,
  evaluateAccountAge,
  type AgeVerdict,
} from '../_shared/google.ts';
import { HttpError, type AccessState } from '../_shared/types.ts';

const FUNCTION_NAME = 'account-age-gate';

type RequestBody = {
  accessToken?: string;
  /** Supabase hands the provider token to the client as `session.provider_token`. */
  providerToken?: string;
  requestId?: string;
  scopes?: string[];
  recheck?: boolean;
};

type ProfileRow = {
  id: string;
  username: string;
  access_state: AccessState;
  access_state_reason: string | null;
  eligibility_attempts: number;
  eligibility_verified_at: string | null;
  eligibility_method: string | null;
  google_email: string | null;
  google_account_created_at: string | null;
  google_account_age_days: number | null;
};

const DAY_MS = 86_400_000;
const now = () => Date.now();

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') {
      throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    }

    const caller = await requireUser(env, bearerToken(req));
    const ip = clientIp(req) ?? 'unknown';
    enforce('age-gate:uid', caller.uid, 6);
    enforce('age-gate:ip', ip, 40);

    const body = await readJsonBody<RequestBody>(req, env.maxBodyBytes);
    const requestId =
      expectString(body.requestId, 'requestId', { optional: true, max: 64, pattern: /^[A-Za-z0-9_.:-]+$/ }) ??
      crypto.randomUUID();

    const admin = adminClient(env);
    const asUser = userClient(env, bearerToken(req)!);

    const { data: profileData, error: profileError } = await asUser
      .from('profiles')
      .select(
        'id, username, access_state, access_state_reason, eligibility_attempts, eligibility_verified_at, eligibility_method, google_email, google_account_created_at, google_account_age_days',
      )
      .eq('id', caller.uid)
      .maybeSingle();
    if (profileError) throw new HttpError('upstream_error', 'could not load the profile');
    const profile = profileData as unknown as ProfileRow | null;
    if (!profile) throw new HttpError('not_found', 'profile row is missing');

    // ── 1. non-Google identities are not subject to the age rule ───────────
    if (caller.provider !== 'google') {
      if (profile.access_state !== 'active') {
        await rpc(admin, 'record_eligibility_check', {
          p_check: {
            user_id: caller.uid,
            request_id: requestId,
            provider: caller.provider,
            method: 'cached',
            verdict: 'passed',
            reason: `${caller.provider} identities are not age-gated`,
            source_ip: ip,
          },
        });
      }
      return ok({
        passed: true,
        skipped: true,
        access_state: 'active',
        reason: `${caller.provider} sign-in: no Google age check required`,
      }, cors);
    }

    // ── 2. replay + cache ──────────────────────────────────────────────────
    const { data: replay } = await admin
      .from('eligibility_checks')
      .select('verdict, account_created_at, account_age_days, method, reason, created_at')
      .eq('request_id', requestId)
      .maybeSingle();
    if (replay) {
      log.info('idempotent replay', { uid: caller.uid, requestId });
      return ok({
        passed: replay.verdict === 'passed',
        replayed: true,
        access_state: profile.access_state,
        verdict: replay.verdict,
        account_created_at: replay.account_created_at,
        account_age_days: replay.account_age_days,
        method: replay.method,
        reason: replay.reason,
      }, cors);
    }

    const verifiedAt = profile.eligibility_verified_at ? Date.parse(profile.eligibility_verified_at) : null;
    const cacheFresh =
      verifiedAt !== null && now() - verifiedAt < env.eligibilityCacheDays * DAY_MS;
    if (profile.access_state === 'active' && cacheFresh && !body.recheck) {
      return ok({
        passed: true,
        cached: true,
        access_state: profile.access_state,
        account_created_at: profile.google_account_created_at,
        account_age_days: profile.google_account_age_days,
        method: profile.eligibility_method,
        checked_at: profile.eligibility_verified_at,
      }, cors);
    }
    if (profile.access_state === 'restricted' && profile.eligibility_attempts >= env.maxEligibilityAttempts) {
      throw new HttpError(
        'rate_limited',
        `Too many verification attempts (${profile.eligibility_attempts}/${env.maxEligibilityAttempts}). Contact support to appeal.`,
        { retryAfterSeconds: 3_600 },
      );
    }

    // ── 3. obtain a Google access token ────────────────────────────────────
    let accessToken =
      expectString(body.accessToken ?? body.providerToken, 'accessToken', { optional: true, max: 4_096 }) ?? null;
    let grantedScopes: string[] = Array.isArray(body.scopes) ? body.scopes.map(String) : [];
    let usedStoredCredential = false;

    if (!accessToken) {
      accessToken = await resolveAccessToken(env, caller.uid);
      usedStoredCredential = accessToken !== null;
    }
    if (!accessToken) {
      throw new HttpError(
        'eligibility_pending',
        'No Google access token available. Sign in with Google (consent prompt) and retry — Massanger needs Gmail/Drive metadata to date the account.',
      );
    }

    // ── 4/5. prove ownership, then measure the account age ─────────────────
    const tokenInfo = await assertTokenOwnership(accessToken, env.googleClientIds, profile.google_email ?? caller.email);
    if (grantedScopes.length === 0 && typeof tokenInfo.scope === 'string') {
      grantedScopes = tokenInfo.scope.split(' ').filter(Boolean);
    }

    let verdict: AgeVerdict;
    try {
      verdict = await evaluateAccountAge({
        accessToken,
        minAgeDays: env.minAccountAgeDays,
        grantedScopes,
        nowMs: now(),
      });
    } catch (error) {
      // An upstream outage must not permanently strand a real user.
      await rpc(admin, 'record_eligibility_check', {
        p_check: {
          user_id: caller.uid,
          request_id: requestId,
          provider: 'google',
          method: 'gmail_profile',
          verdict: 'error',
          min_age_days: env.minAccountAgeDays,
          reason: (error as Error).message.slice(0, 240),
          source_ip: ip,
        },
      });
      throw error;
    }

    log.info('age verdict', {
      uid: caller.uid,
      passed: verdict.passed,
      method: verdict.method,
      age_days: verdict.accountAgeDays,
      signals: redact(verdict.signals),
    });

    // ── 6. persist ─────────────────────────────────────────────────────────
    await rpc(admin, 'record_eligibility_check', {
      p_check: {
        user_id: caller.uid,
        request_id: requestId,
        provider: 'google',
        method: verdict.method,
        verdict: verdict.passed ? 'passed' : 'failed',
        account_created_at: verdict.accountCreatedAt,
        account_age_days: verdict.accountAgeDays,
        min_age_days: env.minAccountAgeDays,
        signals: verdict.signals,
        reason: verdict.reason,
        email: typeof tokenInfo.email === 'string' ? tokenInfo.email : caller.email,
      },
    });

    if (verdict.passed && !usedStoredCredential) {
      // Cache the token we were just handed so a re-check within the hour is free.
      await storeAccessToken(env, caller.uid, {
        email: typeof tokenInfo.email === 'string' ? tokenInfo.email : (caller.email ?? 'unknown'),
        scopes: grantedScopes,
        accessToken,
        expiresAt: new Date(now() + 3_000_000).toISOString(),
      });
    } else if (!verdict.passed && env.blockTooYoung === 'delete') {
      log.warn('deleting ineligible account (AGE_GATE_ON_FAILURE=delete)', { uid: caller.uid });
      // `false`: drop the identity but leave the audit trail (eligibility_checks)
      // behind, because "why was this account refused" is a support question.
      await admin.auth.admin.deleteUser(caller.uid);
    }

    const { data: fresh } = await admin
      .from('profiles')
      .select('access_state, access_state_reason, google_account_age_days, eligibility_verified_at')
      .eq('id', caller.uid)
      .maybeSingle();

    return ok({
      passed: verdict.passed,
      access_state: (fresh?.access_state as AccessState) ?? (verdict.passed ? 'active' : 'restricted'),
      reason: verdict.reason,
      method: verdict.method,
      account_created_at: verdict.accountCreatedAt,
      account_age_days: verdict.accountAgeDays,
      min_age_days: env.minAccountAgeDays,
      checked_at: fresh?.eligibility_verified_at ?? new Date().toISOString(),
      sealing: sealingAvailable(env),
    }, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);