/**
 * One TDLib session per linked Telegram account.
 *
 * Responsibilities (and nothing else):
 *   • own one TdLibClient + its on-disk session directory;
 *   • pump this owner's `telegram_outbox` rows into Telegram, respecting
 *     per-account pacing;
 *   • translate TDLib updates into signed ingest events for the app;
 *   • carry presence and read receipts in both directions;
 *   • report its own liveness so the manager can retire idle sessions.
 *
 * It never talks to the app, and it never holds a plaintext credential longer
 * than a single link handshake (see auth.ts).
 */

import path from 'node:path';
import { mkdir, readFile, stat } from 'node:fs/promises';

import type { BridgeConfig } from './config.js';
import { dedupeKeyFor, tdChatType, type InboundEvent } from './protocol.js';
import {
  IMAGE_MIMES,
  mimeForPath,
  removeIfExists,
  writeTempFile,
} from './media.js';
import {
  mapIncomingMessage,
  planOutbound,
  renderSelfNotice,
  sendOptions,
  type OutboundSend,
  type ResolvedMedia,
  type UploadedMedia,
} from './render.js';
import type { AccountContext, LinkClaim, NotifyRow, OutboxRow } from './supabase.js';
import { SupabaseBridge, SupabaseError } from './supabase.js';
import {
  KoffiTransport,
  TdLibClient,
  TdLibError,
  WebsocketTransport,
  type TdLibTransport,
  type TdObject,
} from './tdlib.js';
import { TelegramSimulator } from './simulator.js';
import { KeyedQueue, TokenBucket, floodWaitSeconds, isAbort, sleep } from './util/backoff.js';
import { logger as rootLogger, type Logger } from './logging.js';
import { completeLinkHandshake, type LinkOutcome } from './auth.js';

export type SessionState = 'init' | 'configuring' | 'awaiting_auth' | 'ready' | 'draining' | 'stopped';

export type TransportFactory = (context: { dataDir: string; ownerUserId: string }) => TdLibTransport;

export type SessionOptions = {
  config: BridgeConfig;
  db: SupabaseBridge;
  context: AccountContext;
  log?: Logger;
  transportFor?: TransportFactory;
  /** Test seam: swap the simulator for a scripted one. */
  simulatorOptions?: ConstructorParameters<typeof TelegramSimulator>[0];
};

export type PumpResult = { sent: number; failed: number; parked: number; presence: number; reads: number };
export type NoticeResult = { sent: number; failed: number; parked: number; skipped: number };

export const TD_INT64_MAX = '9223372036854775807';

/** Chooses the transport named by `BRIDGE_TRANSPORT`. */
export function transportFor(config: BridgeConfig, dataDir: string, ownerUserId: string): TdLibTransport {
  switch (config.transport) {
    case 'koffi':
      if (!config.tdlibLibraryPath) {
        throw new Error('BRIDGE_TRANSPORT=koffi requires TDLIB_LIBRARY_PATH (path to libtdjson.so)');
      }
      return new KoffiTransport(config.tdlibLibraryPath, config.pollIntervalMs);
    case 'websocket':
      if (!config.websocketUrl) throw new Error('BRIDGE_TRANSPORT=websocket requires TD_WS_URL');
      return new WebsocketTransport(config.websocketUrl);
    case 'memory': {
      void dataDir;
      void ownerUserId;
      return new TelegramSimulator({
        phoneCode: process.env.SIM_PHONE_CODE ?? '12345',
        password: process.env.SIM_PASSWORD || null,
      });
    }
    default:
      throw new Error(`unknown BRIDGE_TRANSPORT: ${String(config.transport)}`);
  }
}

type ChatInfo = {
  tgChatId: string;
  /** Our chat uuid, when the mapping is resolved. */
  chatId: string | null;
  type: NonNullable<InboundEvent['tg_chat_type']>;
  title: string | null;
  peerUserId: string | null;
  opened: boolean;
};

export class TelegramSession {
  readonly ownerUserId: string;
  readonly dataDir: string;
  readonly client: TdLibClient;
  readonly log: Logger;

  #state: SessionState = 'init';
  #chats = new Map<string, ChatInfo>();
  /** Own Telegram id and any discovered Saved Messages chat ids: never mirror these. */
  #selfChatIds = new Set<string>();
  /** A sent notice whose DB completion failed: retry the *completion*, not TDLib. */
  #deliveredNotices = new Map<string, { tgMessageId: string | null; selfChatId: string }>();
  #chatQueue = new KeyedQueue<void>();
  #uploaded = new Map<number, UploadedMedia>();
  #tgMessageToOutbox = new Map<string, number>();
  #replyTargets = new Map<string, string | null>();
  #users = new Map<string, TdObject>();
  #inbox: InboundEvent[] = [];
  #flushTimer: ReturnType<typeof setTimeout> | null = null;
  #bucket: TokenBucket;
  #lastSendAt = 0;
  #typingSince = new Date(0);
  #preparing: Promise<void> | null = null;
  #readyResolve: (() => void) | null = null;
  #readyPromise: Promise<void>;
  #authState = 'unknown';
  #detachUpdates: (() => void) | null = null;
  #stopped = false;

  counters = {
    sent: 0,
    failed: 0,
    parked: 0,
    notices: 0,
    notices_failed: 0,
    ingested: 0,
    duplicates: 0,
    downloads: 0,
    uploads: 0,
    errors: 0,
    // "now", so a freshly started session is never reaped before its first pump.
    lastPumpAt: Date.now(),
  };

  constructor(private readonly options: SessionOptions) {
    this.ownerUserId = options.context.user_id;
    if (options.context.tg_user_id != null) this.#selfChatIds.add(String(options.context.tg_user_id));
    this.dataDir = path.join(options.config.dataDir, `tg-${this.ownerUserId}`);
    this.log =
      options.log ?? rootLogger.child({ owner: options.context.username, session: options.config.workerId });
    this.#bucket = new TokenBucket(options.config.maxSendPerMinute);

    const transport =
      options.transportFor?.({ dataDir: this.dataDir, ownerUserId: this.ownerUserId }) ??
      (options.simulatorOptions
        ? new TelegramSimulator(options.simulatorOptions)
        : transportFor(options.config, this.dataDir, this.ownerUserId));

    this.client = new TdLibClient(transport, {
      timeoutMs: options.config.requestTimeoutMs,
      log: { owner: this.ownerUserId, transport: transport.kind },
    });
    this.#readyPromise = new Promise<void>((resolve) => {
      this.#readyResolve = resolve;
    });
  }

  get state(): SessionState {
    return this.#state;
  }

  get authorizationState(): string {
    return this.#authState;
  }

  get ready(): boolean {
    return this.#state === 'ready' && this.#authState === 'ready';
  }

  get stopped(): boolean {
    return this.#stopped;
  }

  /** Resolves once TDLib reports `authorizationStateReady` (or the session fails). */
  whenReady(timeoutMs: number): Promise<void> {
    const existing = this.#readyPromise;
    if (this.#state === 'ready' && this.#authState === 'ready') return Promise.resolve();
    return Promise.race([
      existing,
      sleep(timeoutMs).then(() => {
        throw new Error(`tdlib session for ${this.options.context.username} did not become ready in ${timeoutMs}ms`);
      }),
    ]);
  }

  async start(): Promise<{ state: SessionState; authState: string }> {
    if (this.#state !== 'init') return { state: this.#state, authState: this.#authState };
    this.#state = 'configuring';
    await mkdir(this.dataDir, { recursive: true, mode: 0o700 });

    this.client.on((update) => this.#onUpdate(update));
    try {
      await this.client.start();
    } catch (error) {
      this.#state = 'stopped';
      throw new Error(`cannot start the tdlib transport: ${(error as Error).message}`);
    }

    await this.#setParameters();
    // Either TDLib restored a session (ready immediately) or it is waiting for
    // credentials; both are reported without throwing.
    await this.#awaitAuthorization(2_000);
    if (this.#authState === 'ready') await this.#onReady();
    else this.#state = 'awaiting_auth';
    return { state: this.#state, authState: this.#authState };
  }

  async stop(reason = 'shutdown'): Promise<void> {
    if (this.#stopped) return;
    this.#stopped = true;
    this.#state = 'draining';
    if (this.#flushTimer) clearTimeout(this.#flushTimer);
    await this.#flush({ force: true, reason }).catch((error: Error) =>
      this.log.warn('final ingest flush failed', { reason: error.message }),
    );
    this.#detachUpdates?.();
    await this.client.close().catch(() => undefined);
    await this.#flushTempFiles();
    this.#state = 'stopped';
    this.#readyResolve?.();
  }

  /**
   * Drops TDLib's auth keys. Used for unlink: without `logOut` the session
   * directory keeps a working Telegram authorisation on disk, which would be a
   * worse secret-rotation story than the user expects when they press "unlink".
   */
  async logoutAndStop(userId: string): Promise<void> {
    try {
      await this.client.request('logOut', {}, { timeoutMs: 8_000 });
    } catch (error) {
      this.log.warn('logOut failed; destroying the session anyway', { error: (error as Error).message });
    }
    await this.options.db.setAccountState({ userId, authState: 'unlinked', note: 'unlinked from the app' });
    await this.options.db.failNotify(userId, 'telegram account was unlinked').catch(() => undefined);
    await this.stop('logout');
  }

  // ── linking ───────────────────────────────────────────────────────────────

  async handleLinkRequest(claim: LinkClaim): Promise<LinkOutcome> {
    const outcome = await completeLinkHandshake({
      client: this.client,
      db: this.options.db,
      config: this.options.config,
      claim,
      dataDir: this.dataDir,
      log: this.log,
      onReady: async () => {
        if (this.#state === 'init' || this.#state === 'configuring') await this.#setParameters().catch(() => undefined);
        await this.#onReady();
      },
    });
    if (outcome.result === 'ready') this.#state = 'ready';
    return outcome;
  }

  // ── outbound pump ────────────────────────────────────────────────────────

  async pump(rows: OutboxRow[]): Promise<PumpResult> {
    const result: PumpResult = { sent: 0, failed: 0, parked: 0, presence: 0, reads: 0 };
    this.counters.lastPumpAt = Date.now();

    if (!this.ready) {
      for (const row of rows) {
        await this.options.db
          .completeOutbox({ outboxId: row.outbox_id, state: 'queued', error: 'session not authorised', retrySeconds: 20 })
          .catch((error: Error) => this.log.debug('parking a send failed', { error: error.message }));
        result.parked++;
      }
      return result;
    }

    const byChat = new Map<string, OutboxRow[]>();
    for (const row of rows) {
      const key = String(row.tg_chat_id ?? `msg:${row.message_id}`);
      const list = byChat.get(key);
      if (list) list.push(row);
      else byChat.set(key, [row]);
    }

    await Promise.all(
      [...byChat.entries()].map(([, list]) =>
        this.#chatQueue.enqueue(`send:${list[0]?.tg_chat_id ?? 'none'}`, async () => {
          for (const row of list) {
            const outcome = await this.#sendOne(row);
            if (outcome === 'sent') result.sent++;
            else if (outcome === 'failed') result.failed++;
            else result.parked++;
          }
        }),
      ),
    );

    result.presence = await this.#pumpPresence();
    result.reads = await this.#pumpReads();
    return result;
  }

  // ── offline notices: delivered by this recipient's own TDLib session ─────

  async deliverNotices(rows: NotifyRow[]): Promise<NoticeResult> {
    const result: NoticeResult = { sent: 0, failed: 0, parked: 0, skipped: 0 };
    this.counters.lastPumpAt = Date.now();
    // Saved Messages is one chat. Serialize sends through the same per-chat
    // queue as the outbox, rather than racing two wake-ups for this account.
    for (const row of rows) {
      const chatId = String(row.tg_self_chat_id ?? row.tg_user_id ?? 'self');
      await this.#chatQueue.enqueue(`send:${chatId}`, async () => {
        const outcome = await this.#deliverOneNotice(row);
        result[outcome]++;
      });
    }
    return result;
  }

  async #deliverOneNotice(row: NotifyRow): Promise<keyof NoticeResult> {
    const db = this.options.db;
    if (row.user_id !== this.ownerUserId) {
      this.log.error('notice was claimed for the wrong account', { notify_id: row.notify_id });
      await db.completeNotify({ notifyId: row.notify_id, state: 'failed', error: 'wrong account session' });
      this.counters.notices_failed++;
      return 'failed';
    }
    const alreadySent = this.#deliveredNotices.get(row.notify_id);
    if (alreadySent) {
      // The first send succeeded but PostgREST was unavailable for the receipt.
      // A live session can recover the completion after the lease expires without
      // placing a second Saved Messages bubble on the user's other devices.
      try {
        await db.completeNotify({ notifyId: row.notify_id, state: 'sent', ...alreadySent });
        this.#deliveredNotices.delete(row.notify_id);
        return 'skipped'; // the original send was already counted
      } catch (error) {
        this.log.warn('notice completion still unavailable', { error: (error as Error).message });
        return 'parked';
      }
    }
    if (!this.ready) {
      await db.completeNotify({ notifyId: row.notify_id, state: 'queued', error: 'session not authorised', retrySeconds: 20 });
      return 'parked';
    }

    const chatId = row.tg_self_chat_id ?? row.tg_user_id;
    if (chatId == null || !/^\d+$/.test(String(chatId)) ||
        row.tg_user_id == null || !/^\d+$/.test(String(row.tg_user_id))) {
      await db.completeNotify({ notifyId: row.notify_id, state: 'failed', error: 'Saved Messages chat is unknown' });
      this.counters.notices_failed++;
      return 'failed';
    }
    const fallback = String(chatId);
    this.#selfChatIds.add(fallback);
    this.#selfChatIds.add(String(row.tg_user_id));

    try {
      // TDLib can require a private chat to be created/loaded before sendMessage
      // accepts its id. This is our own Telegram user id, *not* the sender's.
      // The returned chat id is authoritative even if a cached value was stale.
      const self = await this.client.request<TdObject>('createPrivateChat', {
        user_id: String(row.tg_user_id), force: false,
      });
      const target = String(self.id ?? fallback);
      this.#selfChatIds.add(target);
      await this.#pace();
      // A queue claim is not permission to send forever: an app read, mute,
      // foreground heartbeat, or preference change may have happened while we
      // waited for chat creation or Telegram's per-user rate limit.
      if (!(await db.noticeOwed(row.notify_id, row.preview))) {
        await db.completeNotify({ notifyId: row.notify_id, state: 'skipped' });
        return 'skipped';
      }
      const response = await this.client.request<TdObject>('sendMessage', {
        chat_id: target,
        options: {
          '@type': 'messageSendOptions',
          disable_notification: false,
          from_background: true,
          // No sending_id: this isn't an app message and must never correlate
          // with a telegram_outbox bubble on the echo path.
        },
        input_message_content: {
          '@type': 'inputMessageText',
          text: { '@type': 'formattedText', text: renderSelfNotice(row), entities: [] },
          link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: true },
        },
      });
      const actualChat = String(response.chat_id ?? target);
      this.#selfChatIds.add(actualChat);
      const receipt = { tgMessageId: response.id == null ? null : String(response.id), selfChatId: actualChat };
      if (this.#deliveredNotices.size > 1_000) this.#deliveredNotices.delete(this.#deliveredNotices.keys().next().value ?? '');
      this.#deliveredNotices.set(row.notify_id, receipt);
      try {
        const completed = await db.completeNotify({ notifyId: row.notify_id, state: 'sent', ...receipt });
        this.#deliveredNotices.delete(row.notify_id);
        if (!completed) {
          // Read/mute won the race while Telegram accepted the send. The database
          // must *not* resurrect it, even though TDLib cannot unsend that message.
          this.log.debug('notice completed after its lease was cancelled', { notify_id: row.notify_id });
        }
      } catch (error) {
        // Do NOT pass this to the usual failure handler: it would requeue a send
        // that TDLib already accepted. The in-memory receipt above lets the same
        // session finish it when the DB lease is reclaimed.
        this.log.warn('notice sent; will retry its database completion', { error: (error as Error).message });
      }
      this.counters.notices++;
      return 'sent';
    } catch (error) {
      return this.#handleNoticeFailure(row, error);
    }
  }

  async #handleNoticeFailure(row: NotifyRow, error: unknown): Promise<keyof NoticeResult> {
    const db = this.options.db;
    const message = error instanceof Error ? error.message : String(error);
    const flood = floodWaitSeconds(message) ?? (error instanceof TdLibError ? error.floodWaitSeconds : null);
    const fatal = /AUTH_KEY_UNREGISTERED|AUTH_KEY_INVALID|SESSION_REVOKED|SESSION_TERMINATED|USER_DEACTIVATED/i.test(message);
    if (fatal) {
      this.#authState = 'revoked';
      this.#state = 'awaiting_auth';
      await db.setAccountState({ userId: this.ownerUserId, authState: 'needs_reauth', error: message }).catch(() => undefined);
      await db.failPendingSends(this.ownerUserId, 'telegram session was revoked').catch(() => undefined);
      await db.failNotify(this.ownerUserId, 'telegram session was revoked').catch(() => undefined);
      this.counters.notices_failed++;
      return 'failed';
    }

    const badChat = /PEER_ID_INVALID|CHAT_NOT_FOUND|CHAT_WRITE_FORBIDDEN/i.test(message);
    const exhausted = Number(row.attempts ?? 0) >= Number(row.max_attempts ?? 4);
    const permanent = /MESSAGE_EMPTY|INPUT_FETCH_FAILED/i.test(message) ||
      (error instanceof SupabaseError && !error.retryable);
    if (exhausted || permanent) {
      this.counters.notices_failed++;
      await db.completeNotify({ notifyId: row.notify_id, state: 'failed', error: message }).catch(() => undefined);
      return 'failed';
    }

    await db.completeNotify({
      notifyId: row.notify_id,
      state: 'queued',
      error: message,
      resetSelfChat: badChat,
      retrySeconds: flood !== null ? Math.max(2, flood + 2) : badChat ? 60 : 30,
    }).catch((dbError: Error) => this.log.warn('notice retry could not be recorded', { error: dbError.message }));
    return 'parked';
  }

  async #sendOne(row: OutboxRow): Promise<'sent' | 'failed' | 'parked'> {
    const db = this.options.db;
    let tempPath: string | null = null;
    try {
      const chatId = await this.#ensureTgChat(row);
      if (chatId === null) {
        await db.completeOutbox({
          outboxId: row.outbox_id,
          state: 'queued',
          error: 'telegram chat is not resolvable yet',
          retrySeconds: 45,
        });
        return 'parked';
      }

      let media: ResolvedMedia | null = null;
      const mediaRef = row.payload?.media;
      if (mediaRef && (mediaRef.path || mediaRef.url)) {
        tempPath = await this.#fetchAppMedia(mediaRef, row);
        if (tempPath) {
          media = {
            localPath: tempPath,
            mime: mediaRef.mime ?? mimeForPath(mediaRef.path ?? tempPath),
            sizeBytes: mediaRef.size_bytes,
            width: mediaRef.width,
            height: mediaRef.height,
            durationMs: mediaRef.duration_ms,
            waveform: mediaRef.waveform,
          };
        }
      }

      const plan = planOutbound(
        { kind: row.kind, payload: row.payload },
        media,
        { replyToMessageId: await this.#tgMessageIdFor(row.payload?.reply_to) },
      );
      if (plan.sends.length === 0) {
        await db.completeOutbox({ outboxId: row.outbox_id, state: 'skipped', error: plan.note ?? 'nothing to send' });
        return 'parked';
      }

      const options = sendOptions(row.outbox_id);
      let lastMessageId: string | null = null;
      for (const send of plan.sends) {
        await this.#pace();
        const response = await this.#sendMessage(chatId, send, options);
        lastMessageId = String(response.id ?? '');
        if (lastMessageId) this.#tgMessageToOutbox.set(`${chatId}:${lastMessageId}`, row.outbox_id);
      }

      await db.completeOutbox({
        outboxId: row.outbox_id,
        state: 'sent',
        tgMessageId: lastMessageId,
      });
      this.counters.sent++;
      await db
        .setAccountState({ userId: this.ownerUserId, authState: 'linked', note: 'sending', lastSync: true })
        .catch(() => undefined);
      return 'sent';
    } catch (error) {
      return this.#handleSendFailure(row, error);
    } finally {
      await removeIfExists(tempPath);
    }
  }

  async #sendMessage(chatId: string, send: OutboundSend, options: TdObject): Promise<TdObject> {
    const request: Record<string, unknown> = {
      chat_id: chatId,
      options,
      // TDLib 1.8.43 uses an InputMessageReplyTo object, not the older
      // reply_to_message_id request field. Clear-draft belongs to text content.
      ...(send.replyToMessageId
        ? { reply_to: { '@type': 'inputMessageReplyToMessage', message_id: send.replyToMessageId } }
        : {}),
      input_message_content: send.content['@type'] === 'inputMessageText'
        ? { ...send.content, clear_draft: !!send.clearDraft }
        : send.content,
    };
    try {
      return await this.client.request<TdObject>('sendMessage', request);
    } catch (error) {
      // A reply to a message Telegram does not know about is common right after
      // a link (the mapping exists, the history has not been synced). Retry once
      // without the reply instead of losing the message.
      if (error instanceof TdLibError && /MESSAGE_TO_REPLY_NOT_FOUND/i.test(error.message) && send.replyToMessageId) {
        this.log.info('reply target unknown on telegram; sending without the reply link');
        const { reply_to: _dropped, ...rest } = request;
        return await this.client.request<TdObject>('sendMessage', rest);
      }
      throw error;
    }
  }

  async #handleSendFailure(row: OutboxRow, error: unknown): Promise<'failed' | 'parked'> {
    const db = this.options.db;
    const message = error instanceof Error ? error.message : String(error);
    const flood = floodWaitSeconds(message) ?? (error instanceof TdLibError ? error.floodWaitSeconds : null);

    if (flood !== null) {
      this.counters.parked++;
      await db
        .completeOutbox({
          outboxId: row.outbox_id,
          state: 'queued',
          error: `flood_wait_${flood}`,
          retrySeconds: Math.max(2, flood + 2),
        })
        .catch(() => undefined);
      return 'parked';
    }

    const fatal = /AUTH_KEY_UNREGISTERED|AUTH_KEY_INVALID|SESSION_REVOKED|SESSION_TERMINATED|USER_DEACTIVATED/i.test(
      message,
    );
    if (fatal) {
      this.#authState = 'revoked';
      this.#state = 'awaiting_auth';
      this.log.error('telegram revoked this session', { error: message });
      await db
        .setAccountState({ userId: this.ownerUserId, authState: 'needs_reauth', note: null, error: message })
        .catch(() => undefined);
      await db.failPendingSends(this.ownerUserId, 'telegram session was revoked').catch(() => undefined);
    }

    // 400s from Telegram are usually permanent for *this* payload (bad peer id,
    // too-long caption); 5xx and timeouts are worth another attempt.
    const permanent =
      /MESSAGE_EMPTY|CHAT_NOT_FOUND|PEER_ID_INVALID|STORAGE_OUT_OF_MEMORY|INPUT_FETCH_FAILED|FILE_REFERENCE_EXPIRED/i.test(
        message,
      ) || (error instanceof SupabaseError && !error.retryable);
    const attemptsExhausted = Number(row.attempts ?? 0) >= 5;

    if (permanent || attemptsExhausted) {
      this.counters.failed++;
      await db
        .completeOutbox({ outboxId: row.outbox_id, state: 'failed', error: message })
        .catch((dbError: Error) => this.log.error('could not record a failed send', { error: dbError.message }));
      return 'failed';
    }

    this.counters.parked++;
    await db
      .completeOutbox({
        outboxId: row.outbox_id,
        state: 'queued',
        error: message,
        retrySeconds: 30,
      })
      .catch(() => undefined);
    return 'parked';
  }

  /**
   * TDLib needs a Telegram chat id. `bridge_claim_outbox` already coalesces it
   * from `chats.tg_peer_id`, so a null here means the chat has no Telegram
   * counterpart yet (e.g. a MessengerX-only group) and the row is parked, not
   * failed — a later `telegram_set_chat_sync` will make it sendable.
   */
  async #ensureTgChat(row: OutboxRow): Promise<string | null> {
    if (row.tg_chat_id === null || row.tg_chat_id === undefined) return null;
    const chatId = String(row.tg_chat_id);
    if (!this.#chats.has(chatId)) {
      // TDLib only delivers updates for chats it has "opened"; an unknown id is
      // usually a chat created on Telegram while we were offline.
      const chat = await this.client.request<TdObject>('getChat', { chat_id: chatId }).catch(() => null);
      if (chat) await this.#registerChat(chat, { silent: true });
      else return null;
    }
    return chatId;
  }

  /** App media (Storage object) → a local file TDLib can read. */
  async #fetchAppMedia(
    mediaRef: NonNullable<OutboxRow['payload']>['media'],
    row: OutboxRow,
  ): Promise<string | null> {
    if (!mediaRef?.path) return null;
    const bucket = mediaRef.bucket ?? (row.kind === 'voice' ? 'voice-notes' : 'images');
    try {
      const bytes = await this.options.db.download(bucket, mediaRef.path, this.options.config.maxMediaBytes);
      const target = await writeTempFile(
        path.join(this.dataDir, 'outbound'),
        `${row.outbox_id}-${path.basename(mediaRef.path)}`,
        bytes,
      );
      return target;
    } catch (error) {
      this.log.warn('could not fetch outbound media', {
        bucket,
        path: mediaRef.path,
        error: (error as Error).message,
      });
      return null;
    }
  }

  async #tgMessageIdFor(messageId: string | null | undefined): Promise<string | null> {
    if (!messageId) return null;
    const cached = this.#replyTargets.get(messageId);
    if (cached !== undefined) return cached;
    // The app replies by its own message uuid; the Telegram id lives on that row.
    // Replies are rare enough that one indexed lookup beats duplicating the
    // mapping into the outbox payload.
    const map = await this.options.db
      .rpc<Record<string, string | number> | null>('bridge_message_tg_ids', { p_message_ids: [messageId] }, {
        shape: 'scalar',
      })
      .catch(() => null);
    const value = map?.[messageId];
    const resolved = value === null || value === undefined ? null : String(value);
    if (this.#replyTargets.size > 2_000) this.#replyTargets.clear();
    this.#replyTargets.set(messageId, resolved);
    return resolved;
  }

  async #pace(): Promise<void> {
    const minInterval = this.options.config.minSendIntervalMs;
    const sinceLast = Date.now() - this.#lastSendAt;
    if (sinceLast < minInterval) await sleep(minInterval - sinceLast);
    if (!this.#bucket.tryTake()) {
      await sleep(this.#bucket.msUntilAvailable());
    }
    this.#lastSendAt = Date.now();
  }

  async #pumpPresence(): Promise<number> {
    const rows = await this.options.db.pendingTyping(this.ownerUserId, this.#typingSince, 10).catch(() => []);
    let forwarded = 0;
    for (const row of rows) {
      const at = new Date(row.updated_at).getTime();
      if (Number.isFinite(at) && at > this.#typingSince.getTime()) this.#typingSince = new Date(at + 1);
      this.client.notify('sendChatAction', {
        chat_id: String(row.tg_chat_id),
        action: tdChatAction(row.action),
      });
      forwarded++;
    }
    return forwarded;
  }

  async #pumpReads(): Promise<number> {
    const rows = await this.options.db.pendingReads(this.ownerUserId, 25).catch(() => []);
    let applied = 0;
    for (const row of rows) {
      const maxRead = String(row.max_read_message_id);
      this.client.notify('viewMessages', {
        chat_id: String(row.tg_chat_id),
        force_read: true,
        message_viewers: [{ '@type': 'messageViewers', max_read_message_id: maxRead }],
      });
      await this.options.db.markReadsSynced(this.ownerUserId, row.tg_chat_id, maxRead).catch(() => undefined);
      applied++;
    }
    return applied;
  }

  // ── inbound updates ───────────────────────────────────────────────────────

  #isSelfChat(chatId: string | number): boolean {
    const id = String(chatId);
    if (this.#selfChatIds.has(id)) return true;
    const known = this.#chats.get(id);
    return known?.type === 'private' && known.peerUserId != null && this.#selfChatIds.has(known.peerUserId);
  }

  #onUpdate(update: TdObject): void {
    const type = update['@type'];
    switch (type) {
      case 'updateAuthorizationState': {
        // The client already normalises the state; reading it from there keeps one
        // vocabulary for the whole session.
        const state = this.client.authorizationState;
        this.#authState = state;
        if (state === 'ready') {
          void this.#onReady().catch((error: Error) =>
            this.log.warn('post-auth preparation failed', { error: error.message }),
          );
        } else if (state.startsWith('wait') || state === 'closed' || state === 'revoked') {
          this.#state = 'awaiting_auth';
          this.#readyResolve?.();
        }
        return;
      }
      case 'updateConnectionState': {
        const state = String((update.connection_state as TdObject | undefined)?.['@type'] ?? '');
        this.log.debug('telegram connection state', { state });
        return;
      }
      case 'updateNewChat': {
        const chat = update.chat as TdObject | undefined;
        if (chat) void this.#registerChat(chat).catch(() => undefined);
        return;
      }
      case 'updateNewMessage': {
        const message = update.message as TdObject | undefined;
        const chatId = Number(message?.chat_id ?? NaN);
        if (!message || !Number.isFinite(chatId)) return;
        void this.#enqueueInbound(chatId, message, false);
        return;
      }
      case 'updateMessageContent': {
        // Edits arrive as a bare new_content, so rebuild the message envelope:
        // the DB locates the row by (chat, tg_message_id) either way.
        const chatId = Number(update.chat_id ?? NaN);
        const messageId = update.message_id;
        if (!Number.isFinite(chatId) || messageId === undefined) return;
        void this.#enqueueInbound(
          chatId,
          {
            '@type': 'message',
            id: messageId,
            chat_id: chatId,
            date: Math.floor(Date.now() / 1000),
            content: update.new_content,
            is_outgoing: false,
          },
          true,
        );
        return;
      }
      case 'updateDeleteMessages': {
        const ids = (update.message_ids as (string | number)[] | undefined) ?? [];
        const chatId = Number(update.chat_id ?? NaN);
        if (!Number.isFinite(chatId) || ids.length === 0 || this.#isSelfChat(chatId)) return;
        void this.#chatQueue.enqueue(`in:${chatId}`, async () => {
          for (const id of ids) {
            this.#push({
              type: 'message_delete',
              owner_user_id: this.ownerUserId,
              tg_chat_id: String(chatId),
              tg_message_id: String(id),
              dedupe_key: dedupeKeyFor(this.ownerUserId, chatId, 'message_delete', id),
            });
          }
          await this.#scheduleFlush();
        });
        return;
      }
      case 'updateReadOutboxChatHistory': {
        // The peer read our messages → the app's ticks turn blue.
        const chatId = Number(update.chat_id ?? NaN);
        if (!Number.isFinite(chatId) || this.#isSelfChat(chatId)) return;
        void this.#chatQueue.enqueue(`in:${chatId}`, async () => {
          this.#push({
            type: 'read',
            owner_user_id: this.ownerUserId,
            tg_chat_id: String(chatId),
            state: 'read',
            up_to_tg_message_id: String(update.max_read_message_id ?? ''),
            sent_at: new Date().toISOString(),
            dedupe_key: `read:${this.ownerUserId}:${chatId}:${String(update.max_read_message_id ?? 0)}`,
          });
          await this.#scheduleFlush();
        });
        return;
      }
      case 'updateReadInboxChatHistory':
      case 'updateChatReadInbox': {
        // We read the chat *on Telegram* → clear the badge in the app.
        const chatId = Number(update.chat_id ?? NaN);
        if (!Number.isFinite(chatId) || this.#isSelfChat(chatId)) return;
        const upTo = Number(update.max_read_message_id ?? update.last_read_inbox_message_id ?? NaN);
        void this.options.db
          .markInboxRead(this.ownerUserId, chatId, Number.isFinite(upTo) ? upTo : undefined)
          .catch((error: Error) => this.log.debug('inbox read sync failed', { error: error.message }));
        return;
      }
      case 'updateUserChatAction': {
        const chatId = Number(update.chat_id ?? NaN);
        const chat = this.#chats.get(String(chatId));
        if (!Number.isFinite(chatId) || !chat || chat.type !== 'private' || this.#isSelfChat(chatId)) return; // groups: see 00010
        void this.options.db.reportTyping(this.ownerUserId, chatId, String((update.action as TdObject)?.['@type'] ?? ''));
        return;
      }
      case 'updateMessageSendAcknowledged': {
        const chatId = String(update.chat_id ?? '');
        const messageId = String(update.message_id ?? '');
        const outboxId = this.#tgMessageToOutbox.get(`${chatId}:${messageId}`);
        if (!outboxId) return;
        // Delivered to Telegram's servers: the app's single tick becomes two.
        void this.options.db
          .pushEvents([
            {
              type: 'read',
              owner_user_id: this.ownerUserId,
              tg_chat_id: chatId,
              tg_message_id: messageId,
              state: 'delivered',
              outbox_id: String(outboxId),
              sent_at: new Date().toISOString(),
              dedupe_key: `ack:${outboxId}:${messageId}`,
            },
          ])
          .catch(() => undefined);
        return;
      }
      default:
        return;
    }
  }

  #enqueueInbound(chatId: number, message: TdObject, isEdit: boolean): Promise<void> {
    return this.#chatQueue
      .enqueue(`in:${chatId}`, () => this.#ingestMessage(chatId, message, isEdit))
      .catch((error: Error) => {
        if (isAbort(error)) return;
        this.counters.errors++;
        this.log.error('inbound ingest failed', { error: error.message });
      });
  }

  async #ingestMessage(chatIdNumber: number, message: TdObject, isEdit: boolean): Promise<void> {
    const chatId = String(chatIdNumber);
    if (this.#isSelfChat(chatId)) return; // Saved Messages is the notice transport, never an app thread.
    const info = this.#chats.get(chatId);
    if (!info || !info.chatId) {
      // Unknown chat: resolve it first (this is how a new Telegram conversation
      // appears in MessengerX without the user doing anything).
      const chat = await this.client.request<TdObject>('getChat', { chat_id: chatId }).catch(() => null);
      if (chat) await this.#registerChat(chat, { silent: true });
    }
    if (this.#isSelfChat(chatId)) return; // getChat may have revealed a non-obvious self-chat id.
    const known = this.#chats.get(chatId);

    const isOutgoing = message.is_outgoing === true;
    const sender = await this.#senderOf(message);
    const uploaded = await this.#prepareMedia(message, chatId, String(message.id ?? ''), known?.chatId ?? null);

    const mapped = mapIncomingMessage({ message, uploaded: uploaded ?? undefined });
    if (mapped.skip) {
      this.log.debug('skipping inbound message', { reason: mapped.reason, tg_message_id: String(message.id) });
      return;
    }

    // Echo reconciliation, two ways round: `sending_id` is the outbox id we handed
    // TDLib and survives inside `sending_state` on the update, while the local map
    // covers an update that arrives after Telegram cleared the pending state.
    const sendingState = (message.sending_state ?? {}) as Record<string, unknown>;
    const correlation = Number(sendingState.sending_id ?? message.sending_id ?? 0);
    const messageIdKey = `${chatId}:${String(message.id)}`;
    let outboxId = this.#tgMessageToOutbox.get(messageIdKey);
    if (!outboxId && isOutgoing && Number.isFinite(correlation) && correlation > 0) {
      outboxId = correlation;
      this.#tgMessageToOutbox.set(messageIdKey, correlation);
    }
    const event: InboundEvent = {
      type: isEdit ? 'message_edit' : 'message',
      owner_user_id: this.ownerUserId,
      tg_chat_id: chatId,
      tg_chat_type: known?.type ?? 'private',
      tg_message_id: String(message.id ?? ''),
      ...(outboxId ? { tg_send_id: String(outboxId) } : {}),
      kind: mapped.kind,
      body: mapped.body,
      media: mapped.media,
      sent_at: new Date(Number(message.date ?? Math.floor(Date.now() / 1000)) * 1000).toISOString(),
      is_outgoing: isOutgoing,
      reply_to_tg_message_id: message.reply_to_message_id ? String(message.reply_to_message_id) : null,
      dedupe_key: dedupeKeyFor(this.ownerUserId, chatId, isEdit ? 'message_edit' : 'message', String(message.id ?? '')),
      ...(isOutgoing ? {} : sender),
    };

    this.#push(event);
    // Mirror the chat title/peer for brand-new conversations.
    if (!known?.chatId) {
      this.#push({
        type: 'chat',
        owner_user_id: this.ownerUserId,
        tg_chat_id: chatId,
        tg_chat_type: known?.type ?? 'private',
        dedupe_key: dedupeKeyFor(this.ownerUserId, chatId, 'chat'),
        title: known?.title ?? null,
        peer_user_id: known?.peerUserId ?? sender.sender_peer_user_id ?? null,
        peer_first_name: sender.sender_first_name ?? null,
        peer_last_name: sender.sender_last_name ?? null,
        peer_username: sender.sender_username ?? null,
        peer_avatar_url: sender.sender_avatar_url ?? null,
      });
    }
    await this.#scheduleFlush();
  }

  async #senderOf(message: TdObject): Promise<Partial<InboundEvent>> {
    const senderId = message.sender_id as TdObject | undefined;
    const userId = Number(senderId?.user_id ?? NaN);
    const fallback = {
      sender_name: typeof message.sender_name === 'string' ? message.sender_name : null,
    };
    if (!Number.isFinite(userId)) return fallback;

    const user = await this.#userOf(String(userId));
    if (!user) {
      return { sender_peer_user_id: String(userId), ...fallback };
    }
    const name = [String(user.first_name ?? ''), String(user.last_name ?? '')].filter(Boolean).join(' ');
    return {
      sender_peer_user_id: String(userId),
      sender_first_name: String(user.first_name ?? '') || null,
      sender_last_name: String(user.last_name ?? '') || null,
      sender_username: String(user.username ?? '') || null,
      sender_name: name || String(user.username ?? '') || null,
      sender_is_contact: user.is_contact === true,
    };
  }

  /** `getUser` per message would be a second round trip per bubble. */
  async #userOf(userId: string): Promise<TdObject | null> {
    const hit = this.#users.get(userId);
    if (hit) return hit;
    const user = await this.client.request<TdObject>('getUser', { user_id: userId }).catch(() => null);
    if (user && this.#users.size < 5_000) this.#users.set(userId, user);
    return user;
  }

  /**
   * Downloads the media TDLib references (when the owner's preferences allow it)
   * and uploads it to Storage, so the ingest event can carry a real object path
   * instead of a Telegram file id the app could not resolve.
   */
  async #prepareMedia(
    message: TdObject,
    chatId: string,
    messageId: string | number,
    messengerxChatId: string | null,
  ): Promise<Map<number, UploadedMedia> | null> {
    const content = (message.content ?? {}) as TdObject;
    const type = String(content['@type'] ?? '');
    const prefs = this.options.context;

    let fileId: number | null = null;
    let bucket: UploadedMedia['bucket'] = 'images';
    let fallbackMime = 'application/octet-stream';

    if (type === 'messagePhoto') {
      if (!prefs.auto_download_media) return null;
      const photo = (content.photo ?? {}) as TdObject;
      const sizes = (photo.sizes as TdObject[] | undefined) ?? [];
      let best: { id: number; pixels: number } | null = null;
      for (const size of sizes) {
        const id = Number((size.photo_size as TdObject | undefined)?.id ?? NaN);
        if (!Number.isFinite(id)) continue;
        const pixels = Number(size.width ?? 0) * Number(size.height ?? 0);
        if (!best || pixels > best.pixels) best = { id, pixels };
      }
      fileId = best?.id ?? null;
      fallbackMime = 'image/jpeg';
    } else if (type === 'messageVoiceNote') {
      if (!prefs.auto_download_voice) return null;
      const voice = (content.voice_note as TdObject | undefined)?.voice as TdObject | undefined;
      fileId = Number(voice?.id ?? NaN) || null;
      fallbackMime = 'audio/ogg';
      bucket = 'voice-notes';
    } else if (type === 'messageDocument') {
      const document = (content.document as TdObject | undefined)?.document as TdObject | undefined;
      const mime = String((content.document as TdObject | undefined)?.mime_type ?? '');
      if (!IMAGE_MIMES.has(mime) && !mime.startsWith('audio/')) return null;
      if (!prefs.auto_download_media && !prefs.auto_download_voice) return null;
      fileId = Number(document?.id ?? NaN) || null;
      fallbackMime = mime || 'application/octet-stream';
      bucket = mime.startsWith('audio/') ? 'voice-notes' : 'images';
    }

    if (fileId === null) return null;
    const local = await this.#downloadFile(fileId, this.options.config.downloadPriorities[bucket === 'voice-notes' ? 'voice' : type === 'messagePhoto' ? 'photo' : 'other']);
    if (!local) return null;

    const bytes = await readFile(local).catch(() => null);
    if (!bytes) return null;
    if (bytes.byteLength > this.options.config.maxMediaBytes) {
      this.log.info('skipping oversized telegram media', { bytes: bytes.byteLength, fileId });
      return null;
    }

    const contentType = preferMime(fallbackMime, local);
    const ext = extensionFor(contentType) === '.bin' ? path.extname(local) || '.bin' : extensionFor(contentType);
    // Chat-scoped, not owner-scoped: the storage policies read the first path
    // segment as a chat id (`is_chat_member(folder, viewer)`) so every member of
    // the conversation — and only they — can fetch the object. A chat we could not
    // resolve yet gets no upload; the message still mirrors with its placeholder.
    if (!messengerxChatId) {
      this.log.debug('telegram media not uploaded: chat is not mirrored yet', { tg_chat_id: chatId });
      return null;
    }
    const objectPath = `${messengerxChatId}/tg/${chatId}-${String(messageId)}${ext}`;
    try {
      await this.options.db.upload(bucket, objectPath, bytes, contentType);
      this.counters.uploads++;
    } catch (error) {
      this.log.warn('telegram media upload failed', { error: (error as Error).message, objectPath });
      return null;
    }
    return new Map([[fileId, { bucket, path: objectPath, mime: contentType, size: bytes.byteLength }]]);
  }

  async #downloadFile(fileId: number, priority = 1): Promise<string | null> {
    const file = await this.client.request<TdObject>('getFile', { file_id: String(fileId) }).catch(() => null);
    if (!file) return null;
    const local = file.local as TdObject | undefined;
    const existing = typeof local?.path === 'string' ? local.path : null;
    if (existing && (await readable(existing))) {
      this.counters.downloads++;
      return existing;
    }

    await this.client
      .request('downloadFile', {
        file_id: String(fileId),
        // Voice first: a 3-second clip is the message people actually wait for.
        priority,
        synchronous: true,
      })
      .catch((error: Error) => this.log.debug('downloadFile failed', { error: error.message }));

    try {
      const settled = await this.client.waitForUpdate(
        (update) =>
          update['@type'] === 'updateFile' &&
          Number((update.file as TdObject | undefined)?.id) === fileId &&
          (update.file as TdObject | undefined)?.local !== undefined,
        { timeoutMs: 30_000, label: `download of telegram file ${fileId}` },
      );
      const settledLocal = (settled.file as TdObject | undefined)?.local as TdObject | undefined;
      const target = typeof settledLocal?.path === 'string' ? settledLocal.path : existing;
      if (target && (await readable(target))) {
        this.counters.downloads++;
        return target;
      }
    } catch (error) {
      if (!isAbort(error)) this.log.debug('timed out waiting for a telegram file', { fileId });
    }
    return existing && (await readable(existing)) ? existing : null;
  }

  #push(event: InboundEvent): void {
    this.#inbox.push(event);
    // Batching trades a few hundred milliseconds of latency for one signed POST
    // per burst; a full batch goes out immediately instead of waiting.
    if (this.#inbox.length >= this.options.config.ingestBatchSize) {
      void this.#flush({ force: true, reason: 'batch full' });
      return;
    }
    void this.#scheduleFlush();
  }

  async #scheduleFlush(): Promise<void> {
    if (this.#flushTimer || this.#inbox.length === 0) return;
    this.#flushTimer = setTimeout(() => {
      this.#flushTimer = null;
      void this.#flush({ reason: 'timer' });
    }, this.options.config.ingestFlushMs);
    this.#flushTimer.unref?.();
  }

  async #flush(input: { force?: boolean; reason?: string } = {}): Promise<void> {
    if (this.#flushTimer) {
      clearTimeout(this.#flushTimer);
      this.#flushTimer = null;
    }
    if (this.#inbox.length === 0) return;
    const batch = this.#inbox.splice(0, this.options.config.ingestBatchSize);
    try {
      const results = await this.options.db.pushEvents(batch);
      for (const result of results) {
        if (result.status === 'duplicate') this.counters.duplicates++;
        else this.counters.ingested++;
      }
      if (this.#inbox.length > 0) await this.#flush({ force: true, reason: 'overflow' });
    } catch (error) {
      const message = (error as Error).message;
      this.counters.errors++;
      this.log.warn('ingest flush failed', { reason: input.reason, events: batch.length, error: message });
      // Put the batch back and let the ledger dedupe a replay: dropping inbound
      // Telegram traffic silently is the one failure mode we must not have.
      this.#inbox.unshift(...batch);
      const retryIn = Math.min(30_000, 500 * 2 ** Math.min(6, this.counters.errors));
      setTimeout(() => {
        void this.#flush({ force: true, reason: 'retry' });
      }, retryIn).unref?.();
    }
  }

  // ── chat registry ────────────────────────────────────────────────────────

  /**
   * Post-authorisation setup, run exactly once but awaitable by whoever needs it:
   * the update stream and the link handshake both notice `ready`, and the
   * handshake must not report success before the chats are actually open —
   * otherwise the first message after a link races with chat discovery.
   */
  async #onReady(): Promise<void> {
    if (!this.#preparing) {
      this.#preparing = this.#prepareAfterAuth().catch((error: Error) => {
        // Allow a retry on the next `ready`; a half-prepared session must not be
        // cached as "done".
        this.#preparing = null;
        throw error;
      });
    }
    await this.#preparing;
  }

  async #prepareAfterAuth(): Promise<void> {
    this.#state = 'ready';
    this.#readyResolve?.();
    await this.options.db
      .setAccountState({
        userId: this.ownerUserId,
        authState: 'syncing',
        note: 'connected',
        sessionRef: this.sessionRef,
      })
      .catch(() => undefined);
    // On a restored TDLib session the server's user id is authoritative even
    // if the cached account context predates a re-link.
    const me = await this.client.request<TdObject>('getMe', {}).catch(() => null);
    if (me?.id != null) this.#selfChatIds.add(String(me.id));
    await this.#prepareChats();
    await this.options.db
      .setAccountState({ userId: this.ownerUserId, authState: 'linked', note: 'connected', lastSync: true })
      .catch(() => undefined);
  }

  get sessionRef(): string {
    return this.options.context.session_ref ?? path.basename(this.dataDir);
  }

  async #awaitAuthorization(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline && this.#authState === 'unknown') {
      await sleep(50);
    }
  }

  async #setParameters(): Promise<void> {
    const config = this.options.config;
    const params: Record<string, unknown> = {
      api_id: config.apiId,
      api_hash: config.apiHash,
      database_directory: this.dataDir,
      files_directory: path.join(this.dataDir, 'files'),
      use_file_database: true,
      use_chat_info_database: true,
      use_message_database: true,
      use_secret_chats: config.useSecretChats,
      use_test_dc: config.useTestDc,
      system_language_code: config.systemLanguageCode,
      device_model: config.deviceModel,
      system_version: `${process.platform} ${process.arch}`,
      application_version: config.applicationVersion,
    };
    const databaseEncryptionKey = config.databaseEncryptionKey;
    if (databaseEncryptionKey) {
      // The tdjson `bytes` type is a base64 string in JSON, not an array of
      // byte values. A different value here makes a restored session unreadable.
      params.database_encryption_key = databaseEncryptionKey;
    }

    await this.client.request('setTdlibParameters', { '@type': 'setTdlibParameters', ...params }, {
      timeoutMs: Math.max(15_000, config.requestTimeoutMs),
    });
  }

  async #prepareChats(): Promise<void> {
    const chats = await this.#getChats();
    for (const chatId of chats) {
      const chat = await this.client.request<TdObject>('getChat', { chat_id: String(chatId) }).catch(() => null);
      if (chat) await this.#registerChat(chat, { silent: true });
    }
  }

  /**
   * `getChats` lost `offset_order`/`offset_chat_id` in TDLib 1.8.3, so the modern
   * form is tried first and the pre-2024 form is the fallback. Both are answered
   * by the simulator, which is why this compatibility path stays covered.
   */
  async #getChats(): Promise<string[]> {
    const modern = await this.client
      .request<TdObject>('getChats', { chat_list: { '@type': 'chatListMain' }, limit: 100 })
      .catch((error: Error) => ({ __error: error }));
    if (modern && !('__error' in modern)) {
      return ((modern.chat_ids as (string | number)[] | undefined) ?? []).map(String);
    }

    const legacy = await this.client.request<TdObject>('getChats', {
      chat_list: { '@type': 'chatListMain' },
      offset_order: TD_INT64_MAX,
      offset_chat_id: '0',
      limit: 100,
    });
    return ((legacy.chat_ids as (string | number)[] | undefined) ?? []).map(String);
  }

  async #registerChat(chat: TdObject, options: { silent?: boolean } = {}): Promise<void> {
    const tgChatId = String(chat.id ?? '');
    if (!tgChatId || tgChatId === 'undefined') return;

    const type = tdChatType(chat) ?? 'private';
    const title = typeof chat.title === 'string' ? chat.title : null;
    const peerUserId =
      type === 'private' ? String((chat.type as TdObject | undefined)?.user_id ?? '') || null : null;
    if (this.#isSelfChat(tgChatId) || (peerUserId && this.#selfChatIds.has(peerUserId))) {
      this.#selfChatIds.add(tgChatId);
      return; // no resolveChat / openChat / inbound history for Saved Messages
    }

    let peer: { first?: string | null; last?: string | null; username?: string | null; avatar?: string | null } = {};
    if (peerUserId) {
      const user = await this.#userOf(peerUserId);
      if (user) {
        peer = {
          first: String(user.first_name ?? '') || null,
          last: String(user.last_name ?? '') || null,
          username: String(user.username ?? '') || null,
          avatar: firstAvatarUrl(user),
        };
      }
    }

    const info: ChatInfo = this.#chats.get(tgChatId) ?? {
      tgChatId,
      chatId: null,
      type,
      title,
      peerUserId,
      opened: false,
    };
    info.type = type;
    info.title = title ?? info.title;
    info.peerUserId = peerUserId ?? info.peerUserId;
    this.#chats.set(tgChatId, info);

    if (!info.opened) {
      this.client.notify('openChat', { chat_id: tgChatId, limit: 0 });
      info.opened = true;
    }

    if (this.options.context.mirror_to_app) {
      const resolved = await this.options.db
        .resolveChat({
          ownerUserId: this.ownerUserId,
          tgChatId,
          tgChatType: type,
          title,
          peerUserId: peerUserId ?? undefined,
          peerUsername: peer.username,
          peerFirstName: peer.first,
          peerLastName: peer.last,
          peerAvatarUrl: peer.avatar,
          create: true,
        })
        .catch((error: Error) => {
          this.log.warn('could not resolve a telegram chat', { tgChatId, error: error.message });
          return null;
        });
      if (resolved?.chat_id) info.chatId = resolved.chat_id;
      if (!options.silent && resolved?.created) {
        this.log.info('mirror chat created', { tgChatId, chatId: resolved.chat_id });
      }
    }
  }

  async #flushTempFiles(): Promise<void> {
    const dir = path.join(this.dataDir, 'outbound');
    await removeIfExists(dir);
    await mkdir(dir, { recursive: true, mode: 0o700 }).catch(() => undefined);
  }

  metrics(): Record<string, unknown> {
    return {
      owner: this.ownerUserId,
      username: this.options.context.username,
      state: this.#state,
      auth_state: this.#authState,
      transport: this.client.kind,
      chats: this.#chats.size,
      pending_inbox: this.#inbox.length,
      pending_chains: this.#chatQueue.pending,
      ...this.counters,
    };
  }
}

/** TDLib stores chat pictures as `user.photo.avatars[].minithumbnail`/`...[].id`. */
function firstAvatarUrl(user: TdObject): string | null {
  const photo = user.photo as TdObject | undefined;
  const candidates = (photo?.avatars as TdObject[] | undefined) ?? [];
  for (const avatar of candidates) {
    const url = avatar?.url;
    if (typeof url === 'string' && url.startsWith('http')) return url;
  }
  return null;
}

const readable = async (target: string): Promise<boolean> => {
  try {
    const info = await stat(target);
    return info.isFile() && info.size > 0;
  } catch {
    return false;
  }
};

const extensionFor = (mime: string): string => {
  switch (mime) {
    case 'audio/ogg':
    case 'audio/opus':
      return '.ogg';
    case 'image/jpeg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    default:
      return '.bin';
  }
};

const preferMime = (fallback: string, localPath: string): string => {
  const guessed = mimeForPath(localPath);
  // TDLib's file names are hash-like; trust Telegram's own mime instead.
  return guessed === 'application/octet-stream' ? fallback : guessed;
};

/** TDLib `ChatAction` from our stored action name (00010 check constraint). */
export function tdChatAction(action: string): TdObject {
  switch (action) {
    case 'upload_voice':
      return { '@type': 'chatActionUploadAudio' };
    case 'upload_photo':
      return { '@type': 'chatActionUploadPhoto' };
    case 'upload_document':
      return { '@type': 'chatActionUploadDocument' };
    case 'record_audio':
      return { '@type': 'chatActionRecordAudio' };
    case 'record_video':
      return { '@type': 'chatActionRecordVideo' };
    case 'choose_sticker':
      return { '@type': 'chatActionChooseSticker' };
    case 'find_location':
      return { '@type': 'chatActionFindLocation' };
    default:
      return { '@type': 'chatActionTyping' };
  }
}
