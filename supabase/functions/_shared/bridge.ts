/**
 * Edge → bridge signalling.
 *
 * The TDLib worker is a long-running service; it *already* watches the queues
 * through Realtime (and a safety poll). A wake-up call is only a latency
 * optimisation, so failures here must never fail the user-facing request: the
 * queue row is committed before we call, therefore dropping the wake-up only
 * costs ≤ POLL_INTERVAL_MS of delay.
 */

import type { Env } from './env.ts';
import { signRequest } from './crypto.ts';
import { log } from './logger.ts';

export type WakeHint = {
  kind: 'outbox' | 'link' | 'relink' | 'media' | 'chat';
  user_ids: string[];
  /** free-form ids for logging only; the worker re-reads from Postgres */
  ids?: string[];
};

export async function wakeBridge(env: Env, hint: WakeHint): Promise<boolean> {
  if (!env.bridgeBaseUrl) return false;
  const body = JSON.stringify({ ...hint, at: new Date().toISOString() });
  const headers: Record<string, string> = { 'content-type': 'application/json', 'user-agent': 'messengerx-edge' };

  if (env.bridgeToken) headers['authorization'] = `Bearer ${env.bridgeToken}`;
  if (env.bridgeHmacSecret) {
    const { header } = await signRequest(env.bridgeHmacSecret, body);
    headers['x-bridge-signature'] = header;
  }

  try {
    const response = await fetch(`${env.bridgeBaseUrl.replace(/\/+$/, '')}/internal/wake`, {
      method: 'POST',
      headers,
      body,
      signal: AbortSignal.timeout(2_500),
    });
    if (!response.ok) {
      log.warn('bridge wake-up rejected', { status: response.status, kind: hint.kind });
      return false;
    }
    return true;
  } catch (error) {
    log.debug('bridge wake-up failed', { kind: hint.kind, cause: (error as Error).message });
    return false;
  }
}
