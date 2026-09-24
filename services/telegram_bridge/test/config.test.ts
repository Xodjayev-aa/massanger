/**
 * Configuration is the one place where a typo becomes a production outage, so the
 * loader's rules (aliases, fallbacks, hard failures) are asserted directly.
 */

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { ConfigError, loadConfig } from '../src/config.js';
import { testEnv } from './helpers.js';

describe('loadConfig', () => {
  it('fails loudly when the database coordinates are missing', () => {
    assert.throws(
      () => loadConfig({ PATH: '/bin' } as NodeJS.ProcessEnv),
      (error: unknown) => {
        assert.ok(error instanceof ConfigError);
        const issues = (error as ConfigError).issues.join('\n');
        assert.match(issues, /supabaseUrl/);
        assert.match(issues, /serviceRoleKey/);
        return true;
      },
    );
  });

  it('accepts the legacy SUPABASE_SERVICE_KEY name', () => {
    const env = testEnv();
    delete env.SUPABASE_SERVICE_ROLE_KEY;
    env.SUPABASE_SERVICE_KEY = 'legacy-key-that-is-long-enough';
    assert.equal(loadConfig(env).serviceRoleKey, 'legacy-key-that-is-long-enough');
  });

  it('points at the edge function by default and at the RPC when asked', () => {
    const viaFunction = loadConfig(testEnv());
    assert.equal(viaFunction.ingestMode, 'function');
    assert.equal(viaFunction.ingestEndpoint, `${viaFunction.supabaseUrl}/functions/v1/telegram-ingest`);

    const viaRpc = loadConfig(testEnv({ INGEST_MODE: 'rpc' }));
    assert.equal(viaRpc.ingestMode, 'rpc');
    assert.equal(viaRpc.ingestEndpoint, `${viaRpc.supabaseUrl}/rest/v1/rpc/bridge_ingest_message`);
  });

  it('prefers SEAL_KEY but still honours the old LINK_PAYLOAD_KEY', () => {
    assert.equal(loadConfig(testEnv({ SEAL_KEY: 'aa'.repeat(32) })).sealKey, 'aa'.repeat(32));
    const env = testEnv({ LINK_PAYLOAD_KEY: 'bb'.repeat(32) });
    delete env.SEAL_KEY;
    assert.equal(loadConfig(env).sealKey, 'bb'.repeat(32));
  });

  it('keeps the media scratch directory inside the data dir', () => {
    const config = loadConfig(testEnv());
    assert.ok(config.mediaTempDir.startsWith(config.dataDir), config.mediaTempDir);
  });

  it('clamps absurd values instead of trusting the operator', () => {
    const config = loadConfig(
      testEnv({
        BRIDGE_MAX_SEND_PER_MINUTE: '99999',
        BRIDGE_OUTBOX_BATCH_SIZE: '0',
        BRIDGE_MAX_MEDIA_BYTES: '-5',
        BRIDGE_MIN_SEND_INTERVAL_MS: '-100',
      }),
    );
    assert.ok(config.maxSendPerMinute <= 120, `maxSendPerMinute=${config.maxSendPerMinute}`);
    assert.ok(config.outboxBatchSize >= 1);
    assert.ok(config.maxMediaBytes > 0);
    assert.ok(config.minSendIntervalMs >= 0);
  });

  it('never starts with an unknown transport', () => {
    const config = loadConfig(testEnv({ BRIDGE_TRANSPORT: 'carrier-pigeon' }));
    assert.equal(config.transport, 'koffi', 'a typo falls back to the default rather than crash-looping');
  });

  it('requires real Telegram credentials unless the session is simulated', () => {
    assert.throws(
      () =>
        loadConfig({
          ...testEnv(),
          BRIDGE_TRANSPORT: 'koffi',
          TELEGRAM_API_ID: '',
          TELEGRAM_API_HASH: '',
        } as NodeJS.ProcessEnv),
      ConfigError,
    );
    // memory transport is the documented dev mode, so it must not demand them.
    const simulated = loadConfig(
      testEnv({ BRIDGE_TRANSPORT: 'memory', TELEGRAM_API_ID: '', TELEGRAM_API_HASH: '' }),
    );
    assert.equal(simulated.transport, 'memory');
  });

  it('rejects an unsupported stateless login-token export rather than pretending failover works', () => {
    assert.throws(() => loadConfig(testEnv({ TELEGRAM_EXPORT_LOGIN_TOKEN: 'true' })),
      (error: unknown) => error instanceof ConfigError && /TELEGRAM_EXPORT_LOGIN_TOKEN.*persistent/.test(error.message));
  });

  it('accepts a 32-byte base64 TDLib key, not hex or malformed bytes', () => {
    const key = Buffer.alloc(32, 0x17).toString('base64');
    assert.equal(loadConfig(testEnv({ TDLIB_DB_KEY: key })).databaseEncryptionKey, key);
    assert.throws(() => loadConfig(testEnv({ TDLIB_DB_KEY: 'ab'.repeat(32) })),
      (error: unknown) => error instanceof ConfigError && /TDLIB_DB_KEY/.test(error.message));
    assert.throws(() => loadConfig(testEnv({ TDLIB_DB_KEY: 'not-base64' })), ConfigError);
  });

  it('parses ALLOWED_ORIGINS into a list', () => {
    const config = loadConfig(testEnv({ ALLOWED_ORIGINS: 'https://a.example, https://b.example ,' }));
    assert.deepEqual(config.allowedOrigins, ['https://a.example', 'https://b.example']);
  });
});
