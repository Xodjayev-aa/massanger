/**
 * Structured logging.
 *
 * pino's call signature is `log.info(obj, msg)`, which reads badly next to the
 * edge functions (and my own muscle memory) that use `log.info(msg, fields)`.
 * Rather than sprinkle argument swaps through the bridge, one thin wrapper fixes
 * the order once; field names then match the functions so a single log stream
 * greps the same way: {ts, level, fn, worker, owner, ...}.
 */

import { pino, type Logger as PinoLogger } from 'pino';

export type Fields = Record<string, unknown>;

export interface Logger {
  trace(message: string, fields?: Fields): void;
  debug(message: string, fields?: Fields): void;
  info(message: string, fields?: Fields): void;
  warn(message: string, fields?: Fields): void;
  error(message: string, fields?: Fields): void;
  fatal(message: string, fields?: Fields): void;
  child(bindings: Fields): Logger;
  /** The underlying pino instance, for the few callers that want it. */
  readonly raw: PinoLogger;
}

const REDACTED_PATHS = [
  'apiHash',
  'api_hash',
  'api_hash_',
  'token',
  'loginTokenEnc',
  'authorization',
  '*.authorization',
  'payload.code',
  'payload.password',
  'payload.phone',
  '*.code',
  '*.password',
  '*.phone_number',
  '*.refresh_token',
  '*.access_token',
  '*.serviceRoleKey',
  'serviceRoleKey',
  'databaseEncryptionKey',
];

class Wrapper implements Logger {
  constructor(readonly raw: PinoLogger) {}

  #level(level: 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal', message: string, fields?: Fields): void {
    if (fields && Object.keys(fields).length > 0) this.raw[level](fields, message);
    else this.raw[level](message);
  }

  trace(message: string, fields?: Fields): void {
    this.#level('trace', message, fields);
  }
  debug(message: string, fields?: Fields): void {
    this.#level('debug', message, fields);
  }
  info(message: string, fields?: Fields): void {
    this.#level('info', message, fields);
  }
  warn(message: string, fields?: Fields): void {
    this.#level('warn', message, fields);
  }
  error(message: string, fields?: Fields): void {
    this.#level('error', message, fields);
  }
  fatal(message: string, fields?: Fields): void {
    this.#level('fatal', message, fields);
  }

  child(bindings: Fields): Logger {
    return new Wrapper(this.raw.child(bindings));
  }
}

let instance: Logger = new Wrapper(pino({ level: 'silent' }));

export function initLogger(level: string, base: Fields = {}): Logger {
  instance = new Wrapper(
    pino({
      level,
      base: { fn: 'telegram-bridge', pid: process.pid, ...base },
      timestamp: pino.stdTimeFunctions.isoTime,
      redact: { paths: REDACTED_PATHS, censor: '«redacted»' },
    }),
  );
  return instance;
}

/** Safe to import before `initLogger` has run (tests, `--help`, early throws). */
export const logger: Logger = {
  trace: (m, f) => instance.trace(m, f),
  debug: (m, f) => instance.debug(m, f),
  info: (m, f) => instance.info(m, f),
  warn: (m, f) => instance.warn(m, f),
  error: (m, f) => instance.error(m, f),
  fatal: (m, f) => instance.fatal(m, f),
  child: (bindings) => instance.child(bindings),
  get raw() {
    return instance.raw;
  },
};

export const childLogger = (bindings: Fields): Logger => instance.child(bindings);
