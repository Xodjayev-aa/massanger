/**
 * Operations surface: health, readiness, Prometheus metrics, and the wake-up
 * endpoint the edge functions poke.
 *
 * This is the only inbound port the bridge opens, and it is not a data plane —
 * no user content crosses it. `/internal/wake` is therefore authenticated twice
 * over (shared bearer token *and* an HMAC over the exact body, with a timestamp
 * window), because a forged wake-up is a cheap way to make the worker burn
 * Telegram rate limit on somebody else's account.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

import type { BridgeConfig } from './config.js';
import { logger as rootLogger, type Logger } from './logging.js';
import type { BridgeManager } from './manager.js';
import { timingSafeEqualStrings, verifySignatureHeader } from './util/envelope.js';

const MAX_WAKE_BODY_BYTES = 64 * 1024;

/** Node allows repeated headers; our contract does not, so flatten them. */
const singleHeader = (value: string | string[] | undefined): string | null =>
  Array.isArray(value) ? (value[0] ?? null) : (value ?? null);

export type AdminServer = {
  port: number;
  close: () => Promise<void>;
};

export async function startAdminServer(options: {
  config: BridgeConfig;
  manager: BridgeManager;
  log?: Logger;
}): Promise<AdminServer> {
  const log = options.log ?? rootLogger;
  const { config, manager } = options;

  const context = { config, manager, log };
  const server = createServer((request, response) => {
    void route(request, response, context).catch((error: Error) => {
      log.error('admin handler crashed', { error: error.message, path: request.url });
      if (!response.headersSent) json(response, 500, { error: 'internal_error' }, context);
      else response.end();
    });
  });
  server.headersTimeout = 15_000;
  server.requestTimeout = 20_000;

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.healthPort, config.healthHost, () => resolve());
  });

  const address = server.address();
  const port = typeof address === 'object' && address !== null ? address.port : config.healthPort;
  log.info('admin listener up', { host: config.healthHost, port });

  return {
    port,
    close: async () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

type RouteContext = { config: BridgeConfig; manager: BridgeManager; log: Logger };

async function route(request: IncomingMessage, response: ServerResponse, ctx: RouteContext): Promise<void> {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  const method = request.method ?? 'GET';

  if (method === 'OPTIONS') {
    response.writeHead(204, corsHeaders(ctx.config));
    response.end();
    return;
  }

  switch (`${method} ${url.pathname}`) {
    case 'GET /healthz':
      return json(response, 200, {
        ok: true,
        service: 'telegram-bridge',
        version: ctx.config.applicationVersion,
        worker: ctx.config.workerId,
        transport: ctx.config.transport,
        ingest: ctx.config.ingestMode,
        uptime_seconds: Math.round((Date.now() - ctx.manager.startedAt) / 1000),
      }, ctx);

    case 'GET /readyz':
      return json(
        response,
        ctx.manager.ready ? 200 : 503,
        { ready: ctx.manager.ready, ...ctx.manager.metrics() },
        ctx,
      );

    case 'GET /metrics':
      return text(response, 200, renderPrometheus(ctx.manager), ctx);

    case 'GET /sessions':
      return json(response, 200, { sessions: ctx.manager.sessionMetrics() }, ctx);

    case 'POST /internal/wake':
      return wake(request, response, ctx);

    default:
      return json(response, 404, { error: 'not_found' }, ctx);
  }
}

async function wake(request: IncomingMessage, response: ServerResponse, ctx: RouteContext): Promise<void> {
  const body = await readBody(request, MAX_WAKE_BODY_BYTES);
  if (body === null) {
    return json(response, 413, { error: 'body too large' }, ctx);
  }

  if (!authorize(request, body, ctx.config)) {
    ctx.log.warn('rejected an unauthenticated wake-up attempt', {
      ip: request.socket.remoteAddress,
      has_token: request.headers.authorization !== undefined,
      has_signature: request.headers['x-bridge-signature'] !== undefined,
    });
    return json(response, 401, { error: 'unauthorized' }, ctx);
  }

  let payload: { kind?: string; user_ids?: unknown; ids?: unknown };
  try {
    payload = JSON.parse(body) as typeof payload;
  } catch {
    return json(response, 400, { error: 'body must be JSON' }, ctx);
  }

  // `ids` is a hint only. Outbox claims are lease-based (`bridge_claim_outbox`
  // picks whatever is due for that owner), so there is nothing to look up by id —
  // keeping the field in the contract costs nothing and gives the log a breadcrumb.
  const ids = Array.isArray(payload.ids)
    ? payload.ids.filter((value): value is string => typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value))
    : [];

  const userIds = Array.isArray(payload.user_ids)
    ? payload.user_ids.filter((value): value is string => typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value))
    : [];
  const kind = payload.kind === 'outbox' || payload.kind === 'notify' || payload.kind === 'link' || payload.kind === 'relink' || payload.kind === 'media' || payload.kind === 'chat' ? payload.kind : undefined;

  // Answer first: the edge function waits at most 2.5 s and must never have a
  // user-visible request fail because of us.
  const done = json(response, 202, { accepted: true, users: userIds.length, kind: kind ?? 'all' }, ctx);
  void ctx.manager
    .wake({ kind, user_ids: userIds })
    .then((result) =>
      ctx.log.debug('wake processed', {
        kind,
        users: userIds.length,
        ids: ids.length,
        sessions: result.sessions,
        pumped: result.pumped,
      }),
    )
    .catch((error: Error) => ctx.log.warn('wake processing failed', { error: error.message }));
  return done;
}

/**
 * `BRIDGE_TOKEN` and `BRIDGE_HMAC_SECRET` are both checked when both are set; the
 * edge functions send both, and requiring the signature alone would be fine too
 * — the token is the belt for a mis-configured secret.
 */
function authorize(request: IncomingMessage, body: string, config: BridgeConfig): boolean {
  if (!config.bridgeToken && !config.bridgeHmacSecret) {
    // Explicitly insecure, and only reachable when MESSENGERX_ENV=development.
    return config.messengerxEnv === 'development';
  }

  const bearer = (singleHeader(request.headers.authorization) ?? '').replace(/^Bearer\s+/i, '');
  if (config.bridgeToken) {
    if (!timingSafeEqualStrings(bearer, config.bridgeToken)) return false;
  }

  if (config.bridgeHmacSecret) {
    return verifySignatureHeader(
      config.bridgeHmacSecret,
      singleHeader(request.headers['x-bridge-signature']),
      body,
      config.clockSkewSeconds,
    );
  }
  return true;
}

function readBody(request: IncomingMessage, limit: number): Promise<string | null> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let overflowed = false;
    request.on('data', (chunk: Buffer) => {
      if (overflowed) return;
      size += chunk.byteLength;
      if (size > limit) {
        // Stop buffering but keep the stream flowing: destroying the socket here
        // would eat the 413 we are about to write, turning a clean rejection into
        // a client-side network error.
        overflowed = true;
        chunks.length = 0;
        resolve(null);
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      if (!overflowed) resolve(Buffer.concat(chunks).toString('utf8'));
    });
    request.on('error', () => resolve(null));
  });
}

function corsHeaders(config: BridgeConfig): Record<string, string> {
  return {
    'access-control-allow-origin': config.allowedOrigins?.[0] ?? '*',
    'access-control-allow-headers': 'authorization,content-type,x-bridge-signature',
    'access-control-allow-methods': 'GET,POST,OPTIONS',
    'access-control-max-age': '600',
  };
}

function json(response: ServerResponse, status: number, body: unknown, ctx: RouteContext): void {
  const payload = JSON.stringify({ ok: status < 400, ...asObject(body) });
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...corsHeaders(ctx.config),
  });
  response.end(payload);
}

function text(response: ServerResponse, status: number, body: string, ctx: RouteContext): void {
  response.writeHead(status, {
    'content-type': 'text/plain; version=0.0.4; charset=utf-8',
    'cache-control': 'no-store',
    ...corsHeaders(ctx.config),
  });
  response.end(body);
}

const asObject = (value: unknown): Record<string, unknown> =>
  typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : { result: value };

/**
 * Prometheus exposition. Cardinality is intentionally capped: per-owner series
 * only for the handful of gauges an on-call needs, everything else aggregated,
 * because this endpoint is scraped by the same process that hosts the sessions.
 */
export function renderPrometheus(manager: BridgeManager): string {
  const metrics = manager.metrics();
  const lines: string[] = [
    '# TYPE messengerx_bridge_up gauge',
    'messengerx_bridge_up 1',
    '# TYPE messengerx_bridge_uptime_seconds counter',
    `messengerx_bridge_uptime_seconds ${metrics.uptime_seconds}`,
    '# TYPE messengerx_bridge_sessions gauge',
    `messengerx_bridge_sessions ${metrics.sessions}`,
    '# TYPE messengerx_bridge_ready_sessions gauge',
    `messengerx_bridge_ready_sessions ${metrics.ready_sessions}`,
    '# TYPE messengerx_bridge_max_sessions gauge',
    `messengerx_bridge_max_sessions ${metrics.max_sessions}`,
    '# TYPE messengerx_bridge_rows_last_tick gauge',
    `messengerx_bridge_rows_last_tick ${metrics.rows_last_tick}`,
    '# TYPE messengerx_bridge_link_requests_last_tick gauge',
    `messengerx_bridge_link_requests_last_tick ${metrics.link_requests_last_tick}`,
  ];
  for (const [key, value] of Object.entries(metrics.totals)) {
    lines.push(`# TYPE messengerx_bridge_${key}_total counter`, `messengerx_bridge_${key}_total ${value}`);
  }
  for (const session of manager.sessionMetrics() as Record<string, unknown>[]) {
    const owner = String(session.username ?? session.owner ?? 'unknown');
    lines.push(
      '# TYPE messengerx_bridge_session_state gauge',
      `messengerx_bridge_session_state{owner="${sanitize(owner)}",state="${sanitize(String(session.state ?? ''))}"} 1`,
      `messengerx_bridge_pending_inbox{owner="${sanitize(owner)}"} ${Number(session.pending_inbox ?? 0)}`,
      `messengerx_bridge_sent_total{owner="${sanitize(owner)}"} ${Number(session.sent ?? 0)}`,
      `messengerx_bridge_ingested_total{owner="${sanitize(owner)}"} ${Number(session.ingested ?? 0)}`,
    );
  }
  return `${lines.join('\n')}\n`;
}

const sanitize = (value: string): string => value.replace(/[^A-Za-z0-9_.:-]/g, '_').slice(0, 64);
