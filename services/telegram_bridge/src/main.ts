/**
 * Entry point.
 *
 * Startup order matters: config → logger → DB reachability → manager (which
 * resumes sessions) → admin listener. If the database is unreachable we exit
 * non-zero instead of pretending to be healthy, because a container that polls a
 * dead Postgres forever looks identical to a working one from the outside.
 */

import { loadConfig, ConfigError } from './config.js';
import { initLogger, logger } from './logging.js';
import { BridgeManager } from './manager.js';
import { startAdminServer, type AdminServer } from './admin.js';
import { startRealtimeWake, type RealtimeHandle } from './realtime.js';
import { SupabaseBridge } from './supabase.js';

async function main(): Promise<number> {
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    if (error instanceof ConfigError) {
      process.stderr.write(`invalid configuration:\n  - ${error.issues.join('\n  - ')}\n\nsee docs/runbook.md\n`);
      return 78; // EX_CONFIG
    }
    throw error;
  }

  const log = initLogger(config.logLevel, {
    worker: config.workerId,
    env: config.messengerxEnv,
    transport: config.transport,
  });

  const db = new SupabaseBridge(config);

  // Liveness probe of the queue itself, not of HTTP: if the bridge cannot claim,
  // nothing it does afterwards is useful.
  try {
    await db.listSessions(1);
  } catch (error) {
    log.error('database is unreachable; refusing to start', {
      url: config.supabaseUrl,
      error: (error as Error).message,
    });
    return 69; // EX_UNAVAILABLE
  }

  const manager = new BridgeManager({ config, db });
  await manager.start();

  let admin: AdminServer | null = null;
  try {
    admin = await startAdminServer({ config, manager, log });
  } catch (error) {
    log.error('admin listener could not bind', { port: config.healthPort, error: (error as Error).message });
    await manager.stop();
    return 72; // EX_IOERR
  }

  let realtime: RealtimeHandle | null = null;
  try {
    realtime = await startRealtimeWake(
      config,
      (input) => {
        void manager.wake(input).catch((error: Error) => log.debug('realtime wake failed', { error: error.message }));
      },
      log,
    );
  } catch (error) {
    log.warn('realtime wake-up disabled', { error: (error as Error).message });
  }

  log.info('telegram bridge is running', {
    sessions: manager.sessionCount,
    realtime: realtime?.status() ?? 'off',
    ingest: config.ingestMode,
    endpoint: config.ingestEndpoint,
    max_sessions: config.maxSessions,
  });

  let shuttingDown = false;
  let finish!: () => void;
  const running = new Promise<void>((resolve) => {
    finish = resolve;
  });

  const shutdown = async (signal: string, code = 0): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info('shutting down', { signal });
    const timer = setTimeout(() => log.error('graceful shutdown exceeded its budget'), config.gracefulShutdownMs);
    timer.unref?.();
    try {
      await realtime?.close();
      await manager.drain(Math.min(2_000, config.gracefulShutdownMs / 2));
      await manager.stop();
      await admin?.close();
    } catch (error) {
      log.error('shutdown error', { error: (error as Error).message });
      code = 1;
    }
    clearTimeout(timer);
    process.exitCode = code;
    finish();
  };

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('unhandledRejection', (reason) => {
    log.error('unhandled rejection', { reason: reason instanceof Error ? reason.message : String(reason) });
  });
  process.on('uncaughtException', (error) => {
    log.fatal('uncaught exception', { error: error.message, stack: error.stack });
    void shutdown('uncaughtException', 1);
  });

  // The admin listener keeps the event loop alive; this promise resolves when a
  // signal has been handled and drained, so the exit code is deterministic.
  void shuttingDown;
  await running;
  return 0;
}

main()
  .then((code) => {
    if (code !== 0) process.exitCode = code;
  })
  .catch((error: Error) => {
    logger.fatal('fatal bridge error', { error: error.message, stack: error.stack });
    process.exitCode = 1;
  });
