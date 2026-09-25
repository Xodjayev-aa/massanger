/**
 * Supabase Realtime as a *latency* optimisation, nothing more.
 *
 * The manager already polls the queues, so this subscription only removes up
 * to `BRIDGE_POLL_INTERVAL_MS` of tail latency when a message is sent or a user
 * enters a code. It is therefore allowed to fail, disconnect, or never exist
 * (e.g. a self-hosted instance without Realtime) and the bridge is still correct
 * — hence the swallowed errors and the reconnect-with-backoff.
 */

import type { Logger } from './logging.js';

import type { BridgeConfig } from './config.js';
import { backoffDelay } from './util/backoff.js';

/** Minimal structural view of the pieces of supabase-js v2 this module touches. */
type RealtimeChannel = {
  on(
    type: 'postgres_changes',
    filter: { event: string; schema: string; table: string },
    callback: (payload: { new?: Record<string, unknown> }) => void,
  ): RealtimeChannel;
  subscribe: (callback: (state: string) => void) => Promise<string> | void;
};

type RealtimeClient = {
  channel: (name: string, options: Record<string, unknown>) => RealtimeChannel;
  removeChannel: (channel: RealtimeChannel) => Promise<void>;
  realtime: { setAuth: (token: string) => void; disconnect: () => Promise<void> };
};

export type RealtimeWake = (input: { kind?: 'outbox' | 'notify' | 'link' | 'relink' | 'media'; user_ids?: string[] }) => void;

export type RealtimeHandle = {
  close: () => Promise<void>;
  status: () => 'off' | 'connecting' | 'live' | 'failed';
};

const TABLES = [
  { schema: 'public', table: 'telegram_outbox', event: 'INSERT', kind: 'outbox' as const, ownerKey: 'owner_user_id' },
  { schema: 'public', table: 'notify_requests', event: 'INSERT', kind: 'notify' as const, ownerKey: 'user_id' },
  {
    schema: 'public',
    table: 'telegram_link_requests',
    event: 'INSERT',
    kind: 'link' as const,
    ownerKey: 'user_id',
  },
  {
    schema: 'public',
    table: 'telegram_link_requests',
    event: 'UPDATE',
    kind: 'link' as const,
    ownerKey: 'user_id',
  },
];

export async function startRealtimeWake(
  config: BridgeConfig,
  onWake: RealtimeWake,
  log: Logger,
): Promise<RealtimeHandle> {
  let status: 'off' | 'connecting' | 'live' | 'failed' = 'connecting';
  let closed = false;
  let client: RealtimeClient | null = null;
  let channel: RealtimeChannel | null = null;
  let attempt = 0;
  let reconnect: ReturnType<typeof setTimeout> | null = null;

  const close = async (): Promise<void> => {
    closed = true;
    if (reconnect) clearTimeout(reconnect);
    try {
      if (channel) await client?.removeChannel(channel);
      await client?.realtime.disconnect();
    } catch {
      /* already gone */
    }
    client = null;
    channel = null;
    status = 'off';
  };

  const connect = async (): Promise<void> => {
    if (closed) return;
    let createClient: ((url: string, key: string, options: Record<string, unknown>) => RealtimeClient) | undefined;
    try {
      // Loaded lazily: the polling path must work even if the realtime package
      // (or the network to it) is unavailable.
      ({ createClient } = (await import('@supabase/supabase-js')) as unknown as {
        createClient: (url: string, key: string, options: Record<string, unknown>) => RealtimeClient;
      });
    } catch (error) {
      status = 'failed';
      log.warn('realtime unavailable (supabase-js not loadable); polling only', {
        error: (error as Error).message,
      });
      return;
    }

    try {
      client = createClient(config.supabaseUrl, config.serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        realtime: { params: { eventsPerSecond: 20 } },
      });
      // The worker's own identity, not a user's: it is subscribing to queues it
      // is allowed to see, and the payload is never trusted for authorisation.
      client.realtime.setAuth(config.serviceRoleKey);

      const created = client.channel(`messengerx-bridge-${config.workerId}`, {
        config: { broadcast: { self: false }, private: false },
      });
      channel = created;
      for (const subscription of TABLES) {
        channel = channel.on(
          'postgres_changes',
          { event: subscription.event, schema: subscription.schema, table: subscription.table },
          (payload: { new?: Record<string, unknown> }) => {
            const row = payload.new ?? {};
            const owner = row[subscription.ownerKey];
            attempt = 0;
            status = 'live';
            onWake({
              kind: subscription.kind,
              user_ids: typeof owner === 'string' ? [owner] : [],
            });
          },
        );
      }

      const active = channel;
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('realtime subscribe timed out after 10s')), 10_000);
        const settle = (state: string): void => {
          if (state === 'SUBSCRIBED') {
            clearTimeout(timer);
            resolve();
            return;
          }
          if (state === 'CHANNEL_ERROR' || state === 'TIMED_OUT' || state === 'CLOSED') {
            clearTimeout(timer);
            reject(new Error(`realtime channel state ${state}`));
          }
        };
        const outcome = active.subscribe(settle);
        if (outcome && typeof outcome.then === 'function') outcome.then(() => undefined, reject);
      });

      status = 'live';
      log.info('realtime wake-up subscription active', { tables: TABLES.map((t) => `${t.table}:${t.event}`) });
    } catch (error) {
      status = 'failed';
      const delay = backoffDelay(attempt + 1, { baseMs: 1_000, maxMs: 60_000 });
      attempt++;
      log.warn('realtime subscription failed; polling covers correctness', {
        error: (error as Error).message,
        retry_in_ms: delay,
      });
      if (!closed) {
        reconnect = setTimeout(() => void connect(), delay);
        reconnect.unref?.();
      }
    }
  };

  await connect();

  return {
    close,
    status: () => status,
  };
}
