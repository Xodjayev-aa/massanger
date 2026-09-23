/**
 * The admin surface is the only port the bridge exposes: the edge functions wake it
 * through it, and Prometheus scrapes it. Both must stay authenticated, bounded and
 * fast, and the metrics must be valid enough for a scraper to accept.
 */

import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import { renderPrometheus, startAdminServer, type AdminServer } from '../src/admin.js';
import { BridgeManager } from '../src/manager.js';
import { TelegramSimulator } from '../src/simulator.js';
import { SupabaseBridge } from '../src/supabase.js';
import { buildSignatureHeader, timingSafeEqualStrings } from '../src/util/envelope.js';
import { OWNER, recorder, testConfig, until, type Recorder } from './helpers.js';

type Harness = {
  config: ReturnType<typeof testConfig>;
  rec: Recorder;
  manager: BridgeManager;
  admin: AdminServer;
  base: () => string;
  stop: () => Promise<void>;
};

async function boot(overrides: Record<string, string | undefined> = {}): Promise<Harness> {
  const config = testConfig({ BRIDGE_HEALTH_PORT: '0', ...overrides });
  const rec = recorder();
  const db = new SupabaseBridge(config, rec.fetchImpl);
  const sim = new TelegramSimulator({});
  const manager = new BridgeManager({
    config,
    db,
    transportFor: () => sim,
  });
  const admin = await startAdminServer({ config, manager });
  return {
    config,
    rec,
    manager,
    admin,
    base: () => `http://127.0.0.1:${admin.port}`,
    stop: async () => {
      await manager.stop();
      await admin.close();
    },
  };
}

const wake = async (
  harness: Harness,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<{ status: number; json: any; text: string }> => {
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const response = await fetch(`${harness.base()}/internal/wake`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: raw,
  });
  const text = await response.text();
  return { status: response.status, json: text === '' ? null : JSON.parse(text), text };
};

describe('admin server', () => {
  let harness: Harness;

  before(async () => {
    harness = await boot();
  });

  after(async () => {
    await harness.stop();
    await assert.rejects(fetch(`${harness.base()}/healthz`), 'the listener must actually close');
  });

  it('describes the process on /healthz', async () => {
    const response = await fetch(`${harness.base()}/healthz`);
    assert.equal(response.status, 200);
    const body = (await response.json()) as Record<string, unknown>;
    assert.equal(body.ok, true);
    assert.equal(body.service, 'telegram-bridge');
    assert.equal(body.transport, 'memory');
    assert.equal(body.ingest, 'function');
    assert.equal(typeof body.uptime_seconds, 'number');
    assert.equal(response.headers.get('cache-control'), 'no-store');
  });

  it('reports readiness from the manager, not from the listener', async () => {
    const ready = await fetch(`${harness.base()}/readyz`);
    assert.equal(ready.status, 200);
    const body = (await ready.json()) as Record<string, unknown>;
    assert.equal(body.ready, true);
    assert.equal(body.sessions, 0);
  });

  it('exposes Prometheus metrics in the text format', async () => {
    const response = await fetch(`${harness.base()}/metrics`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type') ?? '', /^text\/plain; version=0\.0\.4/);
    const text = await response.text();
    for (const line of text.split('\n')) {
      if (line === '' || line.startsWith('#')) continue;
      assert.match(line, /^messengerx_bridge_[a-z_]+(\{[^\n]*\})? [0-9.]+$/, `unparsable metric: ${line}`);
    }
    assert.match(text, /^messengerx_bridge_up 1$/m);
    assert.match(text, /^messengerx_bridge_sessions 0$/m);
    assert.match(text, /^messengerx_bridge_max_sessions \d+$/m);
    // Counters an on-call dashboard filters on.
    assert.match(text, /^messengerx_bridge_sent_total 0$/m);
  });

  it('renders metrics for a running manager without throwing', () => {
    const rendered = renderPrometheus(harness.manager);
    assert.ok(rendered.endsWith('\n'), 'Prometheus expects a trailing newline');
    assert.equal(rendered.split('\n')[0], '# TYPE messengerx_bridge_up gauge');
  });

  it('lists sessions for operators', async () => {
    const response = await fetch(`${harness.base()}/sessions`);
    assert.deepEqual(((await response.json()) as { sessions: unknown[] }).sessions, []);
  });

  it('404s anything else, without leaking which routes exist', async () => {
    const response = await fetch(`${harness.base()}/internal/nope`, { method: 'POST', body: '{}' });
    assert.equal(response.status, 404);
    assert.equal(((await response.json()) as { error: string }).error, 'not_found');
  });

  it('answers CORS preflight for the operator origin', async () => {
    const response = await fetch(`${harness.base()}/sessions`, { method: 'OPTIONS' });
    assert.equal(response.status, 204);
    assert.equal(response.headers.get('access-control-allow-methods'), 'GET,POST,OPTIONS');
    assert.match(response.headers.get('access-control-allow-headers') ?? '', /x-bridge-signature/);
  });

  describe('POST /internal/wake', () => {
    it('rejects an unauthenticated call', async () => {
      const result = await wake(harness, { kind: 'outbox', user_ids: [OWNER] });
      assert.equal(result.status, 401);
      assert.equal(result.json.error, 'unauthorized');
    });

    it('rejects a wrong token even when the body is well-formed', async () => {
      const result = await wake(harness, { kind: 'outbox', user_ids: [OWNER] }, { authorization: 'Bearer nope' });
      assert.equal(result.status, 401);
    });

    it('rejects a valid token with a body that was not signed', async () => {
      const body = { kind: 'outbox', user_ids: [OWNER] };
      const result = await wake(harness, body, { authorization: `Bearer ${harness.config.bridgeToken}` });
      assert.equal(result.status, 401, 'both credentials are required when both are configured');
    });

    it('rejects a signature replayed past the clock skew', async () => {
      const raw = JSON.stringify({ kind: 'outbox', user_ids: [OWNER] });
      const stale = Math.floor(Date.now() / 1000) - harness.config.clockSkewSeconds - 120;
      const { header } = buildSignatureHeader(harness.config.bridgeHmacSecret ?? '', raw, stale);
      const result = await wake(harness, raw, {
        authorization: `Bearer ${harness.config.bridgeToken}`,
        'x-bridge-signature': header,
      });
      assert.equal(result.status, 401);
    });

    it('rejects a signature computed over a different body', async () => {
      const { header } = buildSignatureHeader(harness.config.bridgeHmacSecret ?? '', '{"kind":"link"}');
      const result = await wake(harness, { kind: 'outbox', user_ids: [OWNER] }, {
        authorization: `Bearer ${harness.config.bridgeToken}`,
        'x-bridge-signature': header,
      });
      assert.equal(result.status, 401, 'the signature must cover the exact bytes');
    });

    it('accepts the edge-function contract and hands the wake to the manager', async () => {
      const raw = JSON.stringify({ kind: 'outbox', user_ids: [OWNER], ids: ['11111111-1111-4111-8111-111111111111'] });
      const { header } = buildSignatureHeader(harness.config.bridgeHmacSecret ?? '', raw);
      const result = await wake(harness, raw, {
        authorization: `Bearer ${harness.config.bridgeToken}`,
        'x-bridge-signature': header,
      });
      assert.equal(result.status, 202);
      assert.deepEqual(result.json, { ok: true, accepted: true, users: 1, kind: 'outbox' });

      // The claim happens off the response path; wait for it instead of sleeping.
      await until(() =>
        harness.rec.calls.some((call) => call.url.includes('bridge_claim_outbox'))
          ? harness.rec.find('bridge_claim_outbox')
          : undefined,
      );
      const claim = harness.rec.find('bridge_claim_outbox')!.json();
      assert.equal(claim.p_owner, OWNER, 'the wake hint scopes the claim to that account');
      assert.equal(claim.p_worker, harness.config.workerId);
      assert.equal(claim.p_limit, harness.config.outboxBatchSize);
      assert.match(String(claim.p_lease), /seconds$/);
    });

    it('drops malformed user ids instead of failing the call', async () => {
      const raw = JSON.stringify({ kind: 'link', user_ids: ['DROP TABLE', OWNER, 42] });
      const { header } = buildSignatureHeader(harness.config.bridgeHmacSecret ?? '', raw);
      const result = await wake(harness, raw, {
        authorization: `Bearer ${harness.config.bridgeToken}`,
        'x-bridge-signature': header,
      });
      assert.equal(result.status, 202);
      assert.equal(result.json.users, 1, 'only the 36-char uuid survives validation');
      assert.equal(result.json.kind, 'link');
    });

    it('refuses an oversized body before buffering it', async () => {
      const padding = 'x'.repeat(70 * 1024);
      const raw = `{"kind":"media","note":"${padding}"}`;
      const { header } = buildSignatureHeader(harness.config.bridgeHmacSecret ?? '', raw);
      const result = await wake(harness, raw, {
        authorization: `Bearer ${harness.config.bridgeToken}`,
        'x-bridge-signature': header,
      });
      assert.equal(result.status, 413);
    });

    it('works with a bearer token alone when no HMAC secret is configured', async () => {
      const solo = await boot({ BRIDGE_HMAC_SECRET: undefined });
      try {
        const result = await wake(solo, { kind: 'relink', user_ids: [OWNER] }, {
          authorization: `Bearer ${solo.config.bridgeToken}`,
        });
        assert.equal(result.status, 202);
        assert.equal(result.json.kind, 'relink');
      } finally {
        await solo.stop();
      }
    });
  });

  it('compares credentials in constant time regardless of content', () => {
    assert.equal(timingSafeEqualStrings('secret', 'secret'), true);
    assert.equal(timingSafeEqualStrings('secret', 'secreu'), false);
    assert.equal(timingSafeEqualStrings('secret', 'secret-longer'), false);
    assert.equal(timingSafeEqualStrings('', ''), true);
  });
});
