/**
 * TDLib JSON-client plumbing.
 *
 * TDLib speaks a JSON protocol with two call styles:
 *   • `execute`   – synchronous, works before authorization, only for a subset
 *   • `send`/`receive` – the async channel; responses are matched to requests by
 *     the `@extra` field we inject, everything else is an `update*` event.
 *
 * The transport is an interface so the same client can talk to:
 *   koffi     – libtdjson.so loaded in-process (default; no sidecar)
 *   websocket – a TDLib JSON proxy/sidecar container
 *   memory    – the built-in simulator (tests, and `BRIDGE_TRANSPORT=memory` for
 *               a full local demo without Telegram credentials)
 */

import { logger } from './logging.js';
import { AbortError, isAbort } from './util/backoff.js';

// ---------------------------------------------------------------------------
// TDLib document model (the subset we touch; unknown fields stay reachable)
// ---------------------------------------------------------------------------

export interface TdObject {
  '@type': string;
  [key: string]: unknown;
}

export type TdValue = string | number | boolean | null | TdObject | readonly TdValue[];

export type FileLocationKind = 'local' | 'remote' | 'pending' | 'missing';

export interface TdFile {
  id: number;
  size: number;
  expected_size: number;
  local?: { path: string; is_downloaded_now?: boolean; downloaded_size?: number };
  remote?: { id: string; is_downloading_active?: boolean; downloaded_size?: number };
}

/** TDLib error object (`@type: 'error'`). */
export class TdLibError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly extra?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'TdLibError';
  }

  /** Telegram's own throttling hint, when present. */
  get floodWaitSeconds(): number | null {
    const match = /(?:FLOOD_WAIT|RETRY_AFTER)_(\d{1,7})/i.exec(this.message);
    return match?.[1] ? Number.parseInt(match[1], 10) : null;
  }

  get retryable(): boolean {
    if (this.floodWaitSeconds !== null) return true;
    return [400, 500, 502, 503, 504].includes(this.code) && !/AUTH_|PHONE_NUMBER_|PASSWORD_|SESSION/i.test(this.message);
  }
}

/**
 * `authorizationStateWaitPhoneNumber` → `wait_phone_number`. Snake case keeps
 * every state comparable across the session, the handshake and the tests without
 * re-deriving TDLib's class names at each call site.
 */
export const normaliseAuthorizationState = (raw: string): string =>
  raw
    .replace(/^authorizationState/, '')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .toLowerCase() || 'unknown';

export const isFd = (value: unknown): value is TdObject =>
  typeof value === 'object' && value !== null && '@type' in (value as TdObject);

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

export interface TdLibTransport {
  readonly kind: 'koffi' | 'websocket' | 'memory';
  start(): Promise<void>;
  stop(): Promise<void>;
  /** Async channel: a single serialized request. */
  send(serialized: string): void;
  /** Synchronous `td_json_client_execute` when the transport can provide it. */
  execute?(serialized: string): string | null;
  onReceive(handler: (raw: string) => void): () => void;
}

/** `koffi`-backed transport: loads libtdjson in-process, no sidecar needed. */
export class KoffiTransport implements TdLibTransport {
  readonly kind = 'koffi' as const;
  #client: unknown = null;
  #receive: ((client: unknown, timeout: number) => string | null) | null = null;
  #send: ((client: unknown, request: string) => void) | null = null;
  #execute: ((client: unknown, request: string) => string | null) | null = null;
  #destroy: ((client: unknown) => void) | null = null;
  #loop: ReturnType<typeof setInterval> | null = null;
  #handlers = new Set<(raw: string) => void>();

  constructor(
    private readonly libraryPath: string,
    private readonly pollIntervalMs = 15,
  ) {}

  async start(): Promise<void> {
    type KoffiLibrary = { func(prototype: string): (...args: never[]) => unknown };
    let koffiLoad: ((path: string) => KoffiLibrary) | undefined;
    try {
      const module = (await import('koffi')) as unknown as { load?: (path: string) => KoffiLibrary };
      koffiLoad = module.load;
      if (typeof koffiLoad !== 'function') throw new Error('koffi.load is unavailable');
    } catch (error) {
      throw new Error(
        `cannot load the koffi FFI bindings (${(error as Error).message}). ` +
          'Install the dependency, or run with BRIDGE_TRANSPORT=websocket / memory.',
      );
    }

    let lib: KoffiLibrary;
    try {
      lib = koffiLoad!(this.libraryPath);
    } catch (error) {
      throw new Error(
        `cannot load ${this.libraryPath}: ${(error as Error).message}. ` +
          'Build TDLib (infra/tdlib) and point TDLIB_LIBRARY_PATH at libtdjson.so, ' +
          'or use BRIDGE_TRANSPORT=memory for a local demo.',
      );
    }

    const create = lib.func('void *td_json_client_create()');
    const send = lib.func('void td_json_client_send(void *client, const char *request)');
    const receive = lib.func('const char *td_json_client_receive(void *client, double timeout)');
    const execute = lib.func('const char *td_json_client_execute(void *client, const char *request)');
    const destroy = lib.func('void td_json_client_destroy(void *client)');

    this.#client = create();
    if (!this.#client) throw new Error('td_json_client_create() returned NULL');
    this.#send = (client, request) => void send(client as never, request as never);
    this.#receive = (client, timeout) => receive(client as never, timeout as never) as string | null;
    this.#execute = (client, request) => execute(client as never, request as never) as string | null;
    this.#destroy = (client) => void destroy(client as never);

    // `receive(client, 0)` is non-blocking; a short interval keeps latency low
    // without parking a thread per session.
    this.#loop = setInterval(() => this.#drain(), this.pollIntervalMs);
    this.#loop.unref?.();
  }

  #drain(): void {
    if (!this.#receive || !this.#client) return;
    try {
      for (let guard = 0; guard < 64; guard++) {
        const raw = this.#receive(this.#client, 0);
        if (!raw) return;
        for (const handler of this.#handlers) handler(raw);
      }
    } catch (error) {
      logger.error('tdlib receive failed', { error: (error as Error).message });
    }
  }

  send(serialized: string): void {
    if (!this.#send || !this.#client) throw new Error('transport not started');
    this.#send(this.#client, serialized);
  }

  execute(serialized: string): string | null {
    if (!this.#execute || !this.#client) throw new Error('transport not started');
    return this.#execute(this.#client, serialized);
  }

  onReceive(handler: (raw: string) => void): () => void {
    this.#handlers.add(handler);
    return () => this.#handlers.delete(handler);
  }

  async stop(): Promise<void> {
    if (this.#loop) clearInterval(this.#loop);
    this.#loop = null;
    this.#handlers.clear();
    if (this.#client && this.#destroy) this.#destroy(this.#client);
    this.#client = null;
  }
}

/** Websocket transport: one JSON document per frame, mirroring the JSON client. */
export class WebsocketTransport implements TdLibTransport {
  readonly kind = 'websocket' as const;
  #socket: WebSocket | null = null;
  #queue: string[] = [];
  #handlers = new Set<(raw: string) => void>();

  constructor(
    private readonly url: string,
    private readonly openTimeoutMs = 10_000,
  ) {}

  async start(): Promise<void> {
    const socket = new WebSocket(this.url);
    const opened = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`websocket open timed out: ${this.url}`)), this.openTimeoutMs);
      socket.addEventListener('open', () => (clearTimeout(timer), resolve()), { once: true });
      socket.addEventListener('error', (event) => {
        clearTimeout(timer);
        reject(new Error(`websocket error: ${(event as unknown as { message?: string }).message ?? 'unknown'}`));
      }, { once: true });
    });
    socket.addEventListener('message', (event: MessageEvent) => {
      const raw = typeof event.data === 'string' ? event.data : String(event.data);
      for (const handler of this.#handlers) handler(raw);
    });
    socket.addEventListener('close', () => {
      this.#socket = null;
    });
    await opened;
    this.#socket = socket;
    for (const pending of this.#queue.splice(0)) socket.send(pending);
  }

  send(serialized: string): void {
    if (!this.#socket) {
      this.#queue.push(serialized);
      return;
    }
    this.#socket.send(serialized);
  }

  onReceive(handler: (raw: string) => void): () => void {
    this.#handlers.add(handler);
    return () => this.#handlers.delete(handler);
  }

  async stop(): Promise<void> {
    this.#handlers.clear();
    try {
      this.#socket?.close(1000, 'bridge shutdown');
    } catch {
      /* already closed */
    }
    this.#socket = null;
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export type TdRequestOptions = { timeoutMs?: number; signal?: AbortSignal };

export type TdClientOptions = {
  timeoutMs?: number;
  log?: Record<string, unknown>;
  /** Called for every update, before request correlation. */
  onUnhandledUpdate?: (update: TdObject) => void;
};

export class TdLibClient {
  #seq = 0;
  #pending = new Map<
    string,
    {
      resolve: (value: TdObject) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
      method: string;
    }
  >();

  #handlers = new Set<(update: TdObject) => void>();
  #lastAuthState = 'unknown';
  #closed = false;
  #detach: (() => void) | null = null;
  readonly startedAt = Date.now();

  constructor(
    private readonly transport: TdLibTransport,
    private readonly options: TdClientOptions = {},
  ) {}

  get kind(): TdLibTransport['kind'] {
    return this.transport.kind;
  }

  get closed(): boolean {
    return this.#closed;
  }

  get pendingRequests(): number {
    return this.#pending.size;
  }

  /**
   * TDLib's own view of the login flow, maintained from the update stream
   * (`wait_phone`, `wait_code`, `wait_password`, `ready`, …). Both the session
   * and the handshake read it here instead of each keeping a copy.
   */
  get authorizationState(): string {
    return this.#lastAuthState;
  }

  async start(): Promise<void> {
    await this.transport.start();
    this.#detach = this.transport.onReceive((raw) => this.#ingest(raw));
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#detach?.();
    this.#detach = null;
    for (const [extra, entry] of this.#pending) {
      clearTimeout(entry.timer);
      entry.reject(new AbortError(`client closed while awaiting ${entry.method} (${extra})`));
    }
    this.#pending.clear();
    this.#handlers.clear();
    await this.transport.stop();
  }

  /** Synchronous pre-authorization calls (`@type` requests TDLib allows). */
  executeSync<T extends TdObject = TdObject>(method: string, params: Record<string, unknown> = {}): T | null {
    const serialized = JSON.stringify({ '@type': method, ...params });
    const raw = this.transport.execute?.(serialized);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as T | T[];
    const single = Array.isArray(parsed) ? parsed[0] : parsed;
    if (single && single['@type'] === 'error') {
      throw new TdLibError(Number(single.code ?? 0), String(single.message ?? 'tdlib error'), single as never);
    }
    return (single ?? null) as T | null;
  }

  request<T extends TdObject = TdObject>(
    method: string,
    params: Record<string, unknown> = {},
    options: TdRequestOptions = {},
  ): Promise<T> {
    if (this.#closed) return Promise.reject(new AbortError('client is closed'));
    const extra = `req-${++this.#seq}`;
    const timeoutMs = options.timeoutMs ?? this.options.timeoutMs ?? 45_000;

    return new Promise<T>((resolve, reject) => {
      // Deliberately not unref()'d: an in-flight request is real work, so it must
      // keep the process (and a test) alive until it resolves or times out.
      const timer = setTimeout(() => {
        this.#pending.delete(extra);
        reject(new Error(`tdlib request ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      const abort = (): void => {
        if (!this.#pending.has(extra)) return;
        const entry = this.#pending.get(extra);
        if (entry) clearTimeout(entry.timer);
        this.#pending.delete(extra);
        reject(new AbortError(`aborted while awaiting ${method}`));
      };
      options.signal?.addEventListener('abort', abort, { once: true });

      this.#pending.set(extra, {
        method,
        timer,
        reject: (error) => {
          options.signal?.removeEventListener('abort', abort);
          reject(error);
        },
        resolve: (value) => {
          options.signal?.removeEventListener('abort', abort);
          resolve(value as T);
        },
      });

      try {
        this.transport.send(JSON.stringify({ '@type': method, ...params, '@extra': extra }));
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(extra);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  /** Fire-and-forget (used by `closeChat`, `sendChatAction`, …). */
  notify(method: string, params: Record<string, unknown> = {}): void {
    if (this.#closed) return;
    try {
      this.transport.send(JSON.stringify({ '@type': method, ...params }));
    } catch (error) {
      logger.debug('tdlib notify failed', { method, error: (error as Error).message, ...this.options.log });
    }
  }

  on(handler: (update: TdObject) => void): () => void {
    this.#handlers.add(handler);
    return () => this.#handlers.delete(handler);
  }

  /** Resolves on the first update matching `predicate`; used by the auth flow. */
  waitForUpdate(
    predicate: (update: TdObject) => boolean,
    options: { timeoutMs?: number; signal?: AbortSignal; label?: string } = {},
  ): Promise<TdObject> {
    const timeoutMs = options.timeoutMs ?? 30_000;
    return new Promise<TdObject>((resolve, reject) => {
      if (this.#closed) {
        reject(new AbortError('client is closed'));
        return;
      }
      const detach = this.on((update) => {
        if (!predicate(update)) return;
        finish();
        resolve(update);
      });
      const timer = setTimeout(() => {
        finish();
        reject(new Error(`timed out after ${timeoutMs}ms waiting for ${options.label ?? 'an update'}`));
      }, timeoutMs);
      const onAbort = (): void => {
        finish();
        reject(new AbortError('aborted while waiting for an update'));
      };
      options.signal?.addEventListener('abort', onAbort, { once: true });

      const finish = (): void => {
        clearTimeout(timer);
        detach();
        options.signal?.removeEventListener('abort', onAbort);
      };
    });
  }

  #ingest(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      logger.warn('ignoring non-JSON tdlib payload', { bytes: raw.length });
      return;
    }
    const events = Array.isArray(parsed) ? (parsed as TdObject[]) : [parsed as TdObject];

    for (const event of events) {
      if (!isFd(event)) continue;
      if (event['@type'] === 'updateAuthorizationState') {
        this.#lastAuthState = normaliseAuthorizationState(
          String((event.authorization_state as TdObject | undefined)?.['@type'] ?? ''),
        );
      }
      const extra = typeof event['@extra'] === 'string' ? event['@extra'] : null;
      if (extra) {
        const entry = this.#pending.get(extra);
        if (entry) {
          this.#pending.delete(extra);
          clearTimeout(entry.timer);
          const code = Number(event.code ?? 0);
          if (event['@type'] === 'error') {
            entry.reject(
              new TdLibError(code, String(event.message ?? 'tdlib error'), {
                method: entry.method,
                ...({ ...event, '@extra': undefined } as Record<string, unknown>),
              }),
            );
          } else {
            entry.resolve(event);
          }
          continue;
        }
      }

      for (const handler of this.#handlers) {
        try {
          handler(event);
        } catch (error) {
          if (!isAbort(error)) {
            logger.error('tdlib update handler failed', {
              update: event['@type'],
              error: (error as Error).message,
            });
          }
        }
      }
      this.options.onUnhandledUpdate?.(event);
    }
  }
}

export const tdErrorOf = (error: unknown): TdLibError | null => (error instanceof TdLibError ? error : null);
