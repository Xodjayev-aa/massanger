/**
 * The session supervisor.
 *
 * Four queues drive everything: `telegram_link_requests` (interactive),
 * `telegram_chat_requests` (public @username discovery), `telegram_outbox`
 * (app → Telegram) and `notify_requests` (offline Saved Messages notices).
 * The manager claims from all four, owns per-account
 * sessions, and keeps the process honest about
 * what it is holding:
 *
 *   • at most `BRIDGE_MAX_SESSIONS` TDLib clients, because each one is threads +
 *     disk + a Telegram connection;
 *   • idle sessions are torn down (their outbox rows simply wait for the next
 *     wake-up), so a quiet account costs nothing;
 *   • a crashed worker's leases are released inside `bridge_claim_outbox`, so a
 *     restart never double-sends;
 *   • every loop is re-entrant-guarded: one slow TDLib call must not start a
 *     second pump that fights it for the same rows.
 */


import type { BridgeConfig } from './config.js';
import { logger as rootLogger, type Logger } from './logging.js';
import type { AccountContext, ChatStartClaim, LinkClaim, NotifyRow } from './supabase.js';
import { SupabaseBridge, SupabaseError } from './supabase.js';
import { TelegramSession, type NoticeResult, type PumpResult, type TransportFactory } from './session.js';
import { TdLibError } from './tdlib.js';
import { floodWaitSeconds, isAbort, sleep } from './util/backoff.js';

export type ManagerOptions = {
  config: BridgeConfig;
  db: SupabaseBridge;
  log?: Logger;
  transportFor?: TransportFactory;
};

export type WakeInput = {
  kind?: 'outbox' | 'notify' | 'link' | 'relink' | 'media' | 'chat';
  user_ids?: string[];
  ids?: string[];
};

export type ManagerMetrics = {
  uptime_seconds: number;
  sessions: number;
  ready_sessions: number;
  max_sessions: number;
  rows_last_tick: number;
  link_requests_last_tick: number;
  last_tick_at: number;
  last_pump_at: number;
  totals: {
    sent: number;
    failed: number;
    ingested: number;
    duplicates: number;
    errors: number;
    link_requests: number;
    chat_requests: number;
    parked: number;
    notices: number;
    notices_failed: number;
  };
};

const LINK_CLAIMS_PER_TICK = 4;
const CHAT_CLAIMS_PER_TICK = 4;

export class BridgeManager {
  readonly startedAt = Date.now();
  #sessions = new Map<string, TelegramSession>();
  #starting = new Map<string, Promise<TelegramSession | null>>();
  #tickBusy = false;
  #stopping = false;
  #log: Logger;
  #transportFor?: TransportFactory;
  #loops = new Map<string, ReturnType<typeof setTimeout>>();

  totals = {
    sent: 0,
    failed: 0,
    ingested: 0,
    duplicates: 0,
    errors: 0,
    link_requests: 0,
    chat_requests: 0,
    parked: 0,
    notices: 0,
    notices_failed: 0,
  };

  lastTick = { at: 0, claims: 0, linkRequests: 0, pump: 0 as number | PumpResult };

  constructor(private readonly options: ManagerOptions) {
    this.#log = options.log ?? rootLogger;
    this.#transportFor = options.transportFor;
  }

  get db(): SupabaseBridge {
    return this.options.db;
  }

  get config(): BridgeConfig {
    return this.options.config;
  }

  get sessionCount(): number {
    return this.#sessions.size;
  }

  get ready(): boolean {
    return !this.#stopping;
  }

  sessionFor(ownerUserId: string): TelegramSession | undefined {
    return this.#sessions.get(ownerUserId);
  }

  async start(): Promise<void> {
    await this.#resumeSessions();
    this.#scheduleLoop('tick', this.config.pollIntervalMs, () => this.tick());
    this.#scheduleLoop('heartbeat', this.config.heartbeatSeconds * 1000, () => this.#heartbeat());
    this.#scheduleLoop('reap', 10_000, () => this.#reapIdle());
    this.#scheduleLoop('notice-prune', 6 * 60 * 60 * 1000, () => this.db.pruneNotify());
    this.#log.info('bridge manager started', {
      worker: this.config.workerId,
      transport: this.config.transport,
      ingest: this.config.ingestMode,
      max_sessions: this.config.maxSessions,
    });
  }

  async stop(): Promise<void> {
    this.#stopping = true;
    for (const timer of this.#loops.values()) clearTimeout(timer);
    this.#loops.clear();

    const sessions = [...this.#sessions.values()];
    await Promise.all(
      sessions.map(async (session) => {
        await session.stop('worker shutdown').catch((error: Error) =>
          this.#log.warn('session did not stop cleanly', { error: error.message }),
        );
      }),
    );
    this.#sessions.clear();
    this.#log.info('bridge manager stopped', { sessions: sessions.length, ...this.totals });
  }

  /** One full pass: link requests, new chats, app sends, then offline notices. */
  async tick(): Promise<{ linkRequests: number; pump: number }> {
    if (this.#tickBusy) return { linkRequests: 0, pump: 0 };
    this.#tickBusy = true;
    this.lastTick.at = Date.now();
    let linkRequests = 0;
    let pump = 0;
    try {
      linkRequests = (await this.#drainLinkRequests()).linkRequestsHandled;
      pump = await this.#drainChatRequests();
      pump += await this.#pumpOutbox();
      pump += await this.#pumpNotify();
    } catch (error) {
      if (!isAbort(error)) {
        this.totals.errors++;
        this.#log.error('bridge tick failed', { error: (error as Error).message });
      }
    } finally {
      this.#tickBusy = false;
    }
    this.lastTick.linkRequests = linkRequests;
    this.lastTick.claims = pump;
    return { linkRequests, pump };
  }

  /**
   * A wake-up hint from an edge function. The queues are the source of truth —
   * this only skips the wait for the next poll, so every failure path here is a
   * log line, never an error back to the user's request.
   */
  async wake(input: WakeInput): Promise<{ sessions: number; pumped: number }> {
    const owners = (input.user_ids ?? []).filter((value) => typeof value === 'string' && value.length > 0);
    let pumped = 0;

    if (input.kind === 'link' || input.kind === 'relink' || owners.length === 0) {
      pumped += (await this.#drainLinkRequests()).linkRequestsHandled;
    }
    if (input.kind === 'chat') {
      for (const owner of owners.slice(0, 50)) pumped += await this.#drainChatRequests(owner);
      if (owners.length === 0) pumped += await this.#drainChatRequests();
      return { sessions: this.#sessions.size, pumped };
    }

    if (owners.length > 0) {
      for (const owner of owners.slice(0, 50)) {
        const session = await this.#ensureSession(owner, { create: true });
        if (input.kind !== 'notify') {
          const rows = await this.db.claimOutbox(owner, this.config.outboxBatchSize).catch(() => []);
          if (rows.length > 0) {
            if (!session) await this.#parkAll(rows, 'no session for this account');
            else {
              const result = await session.pump(rows);
              this.#absorb(result);
            }
            pumped += rows.length;
          }
        }
        if (input.kind === 'notify' || input.kind == null) {
          const notices = await this.db.claimNotify(owner, this.config.outboxBatchSize).catch(() => []);
          if (notices.length > 0) {
            if (!session) await this.#parkNotices(notices, 'no session for this account');
            else this.#absorbNotices(await session.deliverNotices(notices));
            pumped += notices.length;
          }
        }
      }
    } else {
      if (input.kind !== 'notify') pumped += await this.#pumpOutbox();
      if (input.kind === 'notify' || input.kind == null) pumped += await this.#pumpNotify();
    }

    return { sessions: this.#sessions.size, pumped };
  }

  // ── link handshake ───────────────────────────────────────────────────────

  async #drainLinkRequests(): Promise<{ linkRequestsHandled: number }> {
    let handled = 0;
    for (let index = 0; index < LINK_CLAIMS_PER_TICK; index++) {
      const claim = await this.db.claimLinkRequest().catch((error: Error) => {
        this.#log.warn('could not claim a link request', { error: error.message });
        return null;
      });
      if (!claim) break;
      await this.#handleLinkClaim(claim);
      handled++;
    }
    return { linkRequestsHandled: handled };
  }

  async #handleLinkClaim(claim: LinkClaim): Promise<void> {
    this.totals.link_requests++;
    this.#log.info('handling link request', {
      request_id: claim.request_id,
      kind: claim.kind,
      step: claim.step,
      user: claim.profile.username,
    });

    const session = await this.#ensureSession(claim.user_id, { create: true, claim });
    if (!session) {
      await this.db
        .linkProgress({
          requestId: claim.request_id,
          status: 'queued',
          step: claim.step,
          note: 'the bridge is at capacity; your request stays queued',
        })
        .catch(() => undefined);
      return;
    }

    try {
      const outcome = await session.handleLinkRequest(claim);
      this.lastTick.linkRequests = this.totals.link_requests;
      if (outcome.result === 'unlinked') {
        await this.#dropSession(claim.user_id, 'unlinked');
      }
    } catch (error) {
      const message = (error as Error).message;
      this.totals.errors++;
      this.#log.error('link handshake threw', { request_id: claim.request_id, error: message });
      await this.db
        .linkProgress({
          requestId: claim.request_id,
          status: 'failed',
          step: 'failed',
          error: message.slice(0, 400),
          note: 'the bridge could not complete the handshake; try again in a minute',
        })
        .catch(() => undefined);
      await this.#dropSession(claim.user_id, 'link failed');
    }
  }

  // ── new Telegram contacts (public @username only) ───────────────────────

  async #drainChatRequests(owner: string | null = null): Promise<number> {
    let handled = 0;
    for (let index = 0; index < CHAT_CLAIMS_PER_TICK; index++) {
      const claim = await this.db.claimChatRequest(owner).catch((error: Error) => {
        this.#log.warn('could not claim a Telegram username lookup', { error: error.message });
        return null;
      });
      if (!claim) break;
      await this.#handleChatRequest(claim);
      handled++;
    }
    return handled;
  }

  async #handleChatRequest(claim: ChatStartClaim): Promise<void> {
    this.totals.chat_requests++;
    try {
      const session = await this.#ensureSession(claim.user_id, { create: true });
      if (!session?.ready) {
        await this.db.finishChatRequest({ requestId: claim.request_id, retrySeconds: 10 });
        return;
      }
      const chatId = await session.openPublicChat(claim.username);
      const applied = await this.db.finishChatRequest({ requestId: claim.request_id, chatId });
      if (!applied) this.#log.info('username lookup lease expired before completion', { request_id: claim.request_id });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.totals.errors++;
      this.#log.warn('Telegram username lookup failed', { request_id: claim.request_id, error: message });
      const missing = error instanceof TdLibError && /USERNAME_(?:NOT_OCCUPIED|INVALID)|CHAT_NOT_FOUND/i.test(message);
      const retry = !missing && (error instanceof SupabaseError && error.retryable ||
        error instanceof TdLibError && error.floodWaitSeconds !== null && error.floodWaitSeconds <= 90 ||
        /not ready|not mirror.*yet/i.test(message));
      const clientMessage = missing ? 'No Telegram user has that public username.'
        : /not a private user/i.test(message) ? 'That username belongs to a group or channel, not a person.'
        : /Saved Messages/i.test(message) ? 'This is your own Telegram account.'
        : /identity does not match/i.test(message) ? 'Reconnect your Telegram account before starting a chat.'
        : 'Telegram could not open that chat. Try again later.';
      // Never expose the raw TDLib error or a database error to the client.
      await this.db.finishChatRequest({
        requestId: claim.request_id,
        error: clientMessage,
        retrySeconds: retry ? Math.max(10, floodWaitSeconds(message) ?? 10) : null,
      }).catch((finishError: Error) =>
        this.#log.warn('could not complete Telegram username lookup', {
          request_id: claim.request_id, error: finishError.message,
        }),
      );
    }
  }

  // ── outbox ────────────────────────────────────────────────────────────────

  async #pumpOutbox(): Promise<number> {
    const rows: import('./supabase.js').OutboxRow[] = await this.db
      .claimOutbox(null, this.config.outboxBatchSize)
      .catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      if (error instanceof SupabaseError && error.retryable) this.#log.warn('outbox claim retrying', { message });
      else this.#log.debug('outbox claim failed', { message });
      return [];
    });
    if (rows.length === 0) return 0;

    const byOwner = new Map<string, import('./supabase.js').OutboxRow[]>();
    for (const row of rows) {
      const list = byOwner.get(row.owner_user_id);
      if (list) list.push(row);
      else byOwner.set(row.owner_user_id, [row]);
    }

    let touched = 0;
    await Promise.all(
      [...byOwner.entries()].map(async ([owner, ownerRows]) => {
        const session = await this.#ensureSession(owner, { create: true });
        if (!session) {
          await this.#parkAll(ownerRows, 'no session available for this account');
          touched += ownerRows.length;
          return;
        }
        const result = await session.pump(ownerRows);
        this.#absorb(result);
        touched += ownerRows.length;
      }),
    );
    return touched;
  }

  async #pumpNotify(): Promise<number> {
    const rows = await this.db.claimNotify(null, this.config.outboxBatchSize).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      if (error instanceof SupabaseError && error.retryable) this.#log.warn('notice claim retrying', { message });
      else this.#log.debug('notice claim failed', { message });
      return [] as NotifyRow[];
    });
    if (rows.length === 0) return 0;

    const byOwner = new Map<string, NotifyRow[]>();
    for (const row of rows) {
      const list = byOwner.get(row.user_id);
      if (list) list.push(row);
      else byOwner.set(row.user_id, [row]);
    }
    await Promise.all(
      [...byOwner.entries()].map(async ([owner, notices]) => {
        const session = await this.#ensureSession(owner, { create: true });
        if (!session) await this.#parkNotices(notices, 'no session for this account');
        else this.#absorbNotices(await session.deliverNotices(notices));
      }),
    );
    return rows.length;
  }

  async #parkNotices(rows: NotifyRow[], error: string): Promise<void> {
    await Promise.all(rows.map((row) => this.db.completeNotify({
      notifyId: row.notify_id, state: 'queued', error, retrySeconds: 30,
    }).catch(() => undefined)));
    this.totals.parked += rows.length;
  }

  #absorbNotices(result: NoticeResult): void {
    this.totals.notices += result.sent;
    this.totals.notices_failed += result.failed;
    this.totals.parked += result.parked;
  }

  async #parkAll(rows: { outbox_id: number }[], error: string): Promise<void> {
    await Promise.all(
      rows.map((row) =>
        this.db
          .completeOutbox({ outboxId: row.outbox_id, state: 'queued', error, retrySeconds: 30 })
          .catch(() => undefined),
      ),
    );
    this.totals.parked += rows.length;
  }

  #absorb(result: PumpResult): void {
    this.totals.sent += result.sent;
    this.totals.failed += result.failed;
    this.totals.parked += result.parked;
  }

  // ── session lifecycle ─────────────────────────────────────────────────────

  async #ensureSession(
    ownerUserId: string,
    options: { create: boolean; claim?: LinkClaim } = { create: true },
  ): Promise<TelegramSession | null> {
    const existing = this.#sessions.get(ownerUserId);
    if (existing && !existing.stopped) return existing;

    if (!options.create || this.#stopping) return null;
    if (this.#sessions.size >= this.config.maxSessions) {
      this.#log.warn('refusing a new session: BRIDGE_MAX_SESSIONS reached', { owner: ownerUserId });
      return null;
    }

    const inflight = this.#starting.get(ownerUserId);
    if (inflight) return inflight;

    const promise = this.#createSession(ownerUserId, options.claim).finally(() => {
      this.#starting.delete(ownerUserId);
    });
    this.#starting.set(ownerUserId, promise);
    return promise;
  }

  async #createSession(ownerUserId: string, claim?: LinkClaim): Promise<TelegramSession | null> {
    // The real preferences always win: the claim only exists so a brand-new link
    // (no row yet, or a row before `bridge_link_complete`) can be driven.
    const fetched: AccountContext | null = await this.db
      .accountContext(ownerUserId)
      .catch((error: Error) => {
        this.#log.warn('could not read the account context', { owner: ownerUserId, error: error.message });
        return null;
      });

    const context: AccountContext | null = fetched ?? (claim
      ? {
          user_id: claim.user_id,
          username: claim.profile.username,
          tg_user_id: claim.account.tg_user_id,
          auth_state: claim.account.auth_state,
          session_ref: claim.session_ref,
          login_token_enc: claim.account.login_token_enc,
          api_id: claim.account.api_id,
          worker_id: this.config.workerId,
          sync_direction: 'both',
          auto_download_voice: true,
          auto_download_media: true,
          mirror_to_app: true,
          last_sync_at: null,
          access_state: 'active',
        }
      : null);

    if (!context) return null;
    if (!claim && !['linked', 'syncing', 'needs_reauth'].includes(context.auth_state)) return null;
    if (!claim && context.access_state !== 'active') {
      this.#log.info('account is not eligible; leaving its queue alone', {
        owner: context.username,
        access_state: context.access_state,
      });
      return null;
    }

    const session = new TelegramSession({
      config: this.config,
      db: this.db,
      context,
      log: this.#log.child({ owner: context.username }),
      ...(this.#transportFor ? { transportFor: this.#transportFor } : {}),
    });

    this.#sessions.set(ownerUserId, session);
    try {
      const started = await session.start();
      this.#log.info('session started', {
        owner: context.username,
        state: started.state,
        auth: started.authState,
      });
    } catch (error) {
      const message = (error as Error).message;
      this.totals.errors++;
      this.#log.error('session failed to start', { owner: context.username, error: message });
      await session.stop('start failed').catch(() => undefined);
      this.#sessions.delete(ownerUserId);
      return null;
    }
    return session;
  }

  async #dropSession(ownerUserId: string, reason: string): Promise<void> {
    const session = this.#sessions.get(ownerUserId);
    if (!session) return;
    this.#sessions.delete(ownerUserId);
    await session.stop(reason).catch(() => undefined);
  }

  async #resumeSessions(): Promise<void> {
    const rows = await this.db.listSessions(50).catch((error: Error) => {
      this.#log.warn('could not list sessions to resume', { error: error.message });
      return [];
    });

    const resumable = rows.filter((row) => row.auth_state === 'linked' || row.auth_state === 'syncing');
    if (resumable.length === 0) return;
    this.#log.info('resuming sessions', { count: resumable.length });

    for (const row of resumable.slice(0, this.config.maxSessions)) {
      await this.#ensureSession(row.user_id, { create: true });
    }
  }

  /**
   * Idle sessions hold a Telegram connection and two TDLib threads. Once an
   * account has nothing queued and has been quiet for a while, we let it go: the
   * next app message re-opens it via the wake hint, and TDLib's session files on
   * disk mean the user does not have to scan anything again.
   */
  async #reapIdle(): Promise<void> {
    const idleMs = this.config.sessionIdleSeconds * 1000;
    if (!idleMs || idleMs <= 0) return;
    const now = Date.now();
    for (const [owner, session] of this.#sessions) {
      if (now - session.counters.lastPumpAt < idleMs) continue;
      if (session.state === 'awaiting_auth') {
        // Never reap a session a user is mid-handshake with.
        continue;
      }
      const pending = await this.db
        .claimOutbox(owner, 1)
        .then((rows) => {
          if (rows.length > 0) void this.#parkAll(rows, 'requeue check');
          return rows.length;
        })
        .catch(() => 0);
      if (pending > 0) continue;
      this.#log.info('reaping an idle session', { owner, idle_ms: now - session.counters.lastPumpAt });
      this.#sessions.delete(owner);
      await session.stop('idle').catch(() => undefined);
    }
  }

  /**
   * Heartbeat: proves to the app (and to whoever is watching Grafana) that a
   * linked account is still owned by *this* worker, and lets a dead worker's
   * accounts be taken over. `auth_state` is not advanced here, only refreshed.
   */
  async #heartbeat(): Promise<void> {
    if (this.#sessions.size === 0) return;
    await Promise.all(
      [...this.#sessions.entries()].map(async ([owner, session]) => {
        if (!session.ready) return;
        await this.db
          .setAccountState({
            userId: owner,
            authState: 'linked',
            note: 'connected',
            sessionRef: session.sessionRef,
            lastSync: true,
          })
          .catch((error: Error) => this.#log.debug('heartbeat failed', { owner, error: error.message }));
      }),
    );
  }

  /**
   * A self-rescheduling timer per loop (not setInterval): a pump that overruns
   * its interval never overlaps itself, and one handle per loop keeps shutdown
   * exact.
   */
  #scheduleLoop(name: string, intervalMs: number, task: () => Promise<unknown>): void {
    const arm = (delay: number): void => {
      const timer = setTimeout(() => {
        void (async () => {
          if (this.#stopping) return;
          try {
            await task();
          } catch (error) {
            if (!isAbort(error)) {
              this.#log.error(`${name} loop failed`, { error: (error as Error).message });
            }
          }
          arm(Math.max(100, intervalMs));
        })();
      }, delay);
      timer.unref?.();
      this.#loops.set(name, timer);
    };
    arm(Math.max(50, Math.floor(intervalMs / 2)));
  }

  metrics(): ManagerMetrics {
    const sessions = [...this.#sessions.values()];
    return {
      uptime_seconds: Math.round((Date.now() - this.startedAt) / 1000),
      sessions: sessions.length,
      ready_sessions: sessions.filter((session) => session.ready).length,
      max_sessions: this.config.maxSessions,
      rows_last_tick: this.lastTick.claims,
      link_requests_last_tick: this.lastTick.linkRequests,
      last_tick_at: this.lastTick.at,
      last_pump_at: Math.max(this.lastTick.at, ...sessions.map((session) => session.counters.lastPumpAt), 0),
      totals: { ...this.totals },
    };
  }

  sessionMetrics(): Record<string, unknown>[] {
    return [...this.#sessions.values()].map((session) => session.metrics());
  }

  /** Used by tests and by graceful-shutdown paths that must not hang forever. */
  async drain(maxMs = 5_000): Promise<void> {
    const deadline = Date.now() + maxMs;
    while (Date.now() < deadline && this.#tickBusy) await sleep(50);
  }
}
