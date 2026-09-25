/**
 * Compatibility endpoint for older clients that call `account-age-gate`.
 *
 * No Google consumer-account creation timestamp is available from the
 * documented Gmail profile API. Imported messages and Drive files cannot prove
 * account age. This endpoint must NEVER grant access based on those signals.
 * Only the database (migration 00013 + operator moderation) owns access_state.
 * New clients read their profile instead of invoking this endpoint.
 */

import { readEnv } from '../_shared/env.ts';
import { configureLogger } from '../_shared/logger.ts';
import { bearerToken, clientIp, corsHeaders, ok, withEnvelope } from '../_shared/http.ts';
import { requireUser, userClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';

const FUNCTION_NAME = 'account-age-gate';

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    const token = bearerToken(req);
    const caller = await requireUser(env, token);
    enforce('access-status:uid', caller.uid, 30);
    enforce('access-status:ip', clientIp(req) ?? 'unknown', 120);

    const asUser = userClient(env, token!);
    const { data, error } = await asUser.from('profiles')
      .select('access_state, access_state_reason')
      .eq('id', caller.uid).maybeSingle();
    if (error) throw new HttpError('upstream_error', 'could not load access state');
    if (!data) throw new HttpError('not_found', 'profile row is missing');

    return ok({
      passed: data.access_state === 'active',
      access_state: data.access_state,
      reason: data.access_state_reason ?? 'Account access is controlled by the server.',
      method: 'auth_provider',
    }, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);
