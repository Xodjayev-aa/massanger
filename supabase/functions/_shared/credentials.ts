/**
 * Google OAuth token custody.
 *
 * Stored tokens live in `public.google_credentials`, which has no client-visible
 * RLS policy and no column grants: the only way in is the service role held by
 * these functions. The refresh token itself is only ever written by trusted
 * server-side code paths (never from a client-supplied body), and it is sealed
 * with SEAL_KEY (AES-256-GCM) so a WAL dump or a read-replica snapshot does not
 * hand over a Google account.
 */

import { aesKeyFromSecret, open, seal } from './crypto.ts';
import type { Env } from './env.ts';
import { adminClient } from './supabase.ts';
import { refreshAccessToken, revokeAccessToken } from './google.ts';
import { log } from './logger.ts';

type Sealed = string;

const sealJson = async (env: Env, value: Record<string, string>): Promise<Sealed> => {
  const key = env.sealKey ? await aesKeyFromSecret(env.sealKey) : null;
  return JSON.stringify(await seal(value as never, key));
};

const unsealJson = async (env: Env, sealed: Sealed): Promise<Record<string, string>> => {
  const key = env.sealKey ? await aesKeyFromSecret(env.sealKey) : null;
  const opened = await open(JSON.parse(sealed) as never, key);
  return ((opened as unknown as { data?: Record<string, string> }).data ??
    opened) as Record<string, string>;
};

export async function storeAccessToken(
  env: Env,
  uid: string,
  values: { email: string; scopes: string[]; accessToken: string; expiresAt: string },
): Promise<void> {
  const admin = adminClient(env);
  await admin.from('google_credentials').upsert(
    {
      user_id: uid,
      email: values.email || 'unknown',
      scopes: values.scopes,
      access_token_enc: await sealJson(env, { access_token: values.accessToken }),
      access_token_exp: values.expiresAt,
      revoked_at: null,
      granted_at: new Date().toISOString(),
    },
    { onConflict: 'user_id' },
  );
}

/**
 * Server-side only: called when a native Google Sign-In flow (which *can* obtain
 * an offline refresh token) is used instead of the browser OAuth redirect. The
 * id token is validated against the configured client ids before anything is
 * stored, so a client cannot push a stranger's refresh token into our vault.
 */
export async function storeRefreshToken(
  env: Env,
  uid: string,
  refreshToken: string,
  email: string,
  scopes: string[],
): Promise<void> {
  const admin = adminClient(env);
  await admin.from('google_credentials').upsert(
    {
      user_id: uid,
      email: email || 'unknown',
      scopes,
      refresh_token_enc: await sealJson(env, { refresh_token: refreshToken }),
      revoked_at: null,
      granted_at: new Date().toISOString(),
    },
    { onConflict: 'user_id' },
  );
}

export async function resolveAccessToken(env: Env, uid: string): Promise<string | null> {
  const admin = adminClient(env);
  const { data } = await admin
    .from('google_credentials')
    .select('refresh_token_enc, access_token_enc, access_token_exp')
    .eq('user_id', uid)
    .maybeSingle();
  if (!data) return null;

  if (data.access_token_enc && data.access_token_exp && Date.parse(data.access_token_exp) > Date.now() + 60_000) {
    try {
      const opened = await unsealJson(env, data.access_token_enc as string);
      if (typeof opened.access_token === 'string' && opened.access_token.length > 20) return opened.access_token;
    } catch (error) {
      log.warn('stored access token could not be opened', { reason: (error as Error).message });
    }
  }

  if (!data.refresh_token_enc || !env.googleClientId || !env.googleClientSecret) return null;
  let refreshToken: string | null = null;
  try {
    const opened = await unsealJson(env, data.refresh_token_enc as string);
    refreshToken = typeof opened.refresh_token === 'string' ? opened.refresh_token : null;
  } catch (error) {
    log.warn('stored refresh token could not be opened', { reason: (error as Error).message });
    return null;
  }
  if (!refreshToken) return null;

  const refreshed = await refreshAccessToken({
    clientId: env.googleClientId,
    clientSecret: env.googleClientSecret,
    refreshToken,
  });
  await storeAccessToken(env, uid, {
    email: '',
    scopes: refreshed.scope.split(' ').filter(Boolean),
    accessToken: refreshed.accessToken,
    expiresAt: new Date(Date.now() + refreshed.expiresInSeconds * 1000).toISOString(),
  });
  return refreshed.accessToken;
}

export async function dropCredential(env: Env, uid: string): Promise<void> {
  const admin = adminClient(env);
  const { data } = await admin.from('google_credentials').select('access_token_enc').eq('user_id', uid).maybeSingle();
  if (data?.access_token_enc) {
    try {
      const opened = await unsealJson(env, data.access_token_enc as string);
      if (typeof opened.access_token === 'string') await revokeAccessToken(opened.access_token);
    } catch (error) {
      log.debug('google revoke skipped', { reason: (error as Error).message });
    }
  }
  await admin.from('google_credentials').update({ revoked_at: new Date().toISOString() }).eq('user_id', uid);
}
