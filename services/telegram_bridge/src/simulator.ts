/**
 * In-process TDLib simulator (`BRIDGE_TRANSPORT=memory`).
 *
 * Two jobs:
 *   1. tests assert the bridge's behaviour against a scripted Telegram instead
 *      of mocking each call site;
 *   2. `npm run bridge` on a laptop with no libtdjson.so and no Telegram api_id
 *      still exercises link → send → ingest end to end against a local
 *      Supabase, which is the fastest way to develop the app.
 *
 * It implements the request/update subset this bridge uses, with the same async
 * shape as the JSON client (responses arrive after the request returns).
 */

import type { TdLibTransport, TdObject } from './tdlib.js';

export type SimulatorOptions = {
  /** The code the simulated user texts us; anything else fails. */
  phoneCode?: string;
  /** Two-factor password; when set, the flow pauses in `wait_password`. */
  password?: string | null;
  myUserId?: number;
  /** ms between a send and its "delivered" transition. */
  deliveryDelayMs?: number;
  chats?: SimulatorChat[];
};

export type SimulatorChat = {
  id: number;
  title?: string;
  type?: 'private' | 'basic_group' | 'supergroup';
  peerUserId?: number;
  peerName?: string;
};

export class TelegramSimulator implements TdLibTransport {
  readonly kind = 'memory' as const;

  #handlers = new Set<(raw: string) => void>();
  #authorization:
    | { state: 'started' | 'wait_phone' | 'wait_code' | 'wait_password' | 'ready' | 'closing' | 'closed'; phone?: string }
    = { state: 'started' };

  #messageId = 1_000;
  #chatId = 2_000;
  #fileId = 3_000;
  #chats: SimulatorChat[];
  #myId: number;
  #sent: TdObject[] = [];
  #actions: TdObject[] = [];
  /** chat_id → highest message id we have "read" (drives read receipts). */
  #readCursors = new Map<number, number>();
  #scripted: { type: string; code: number; message: string }[] = [];
  stopped = false;

  constructor(private readonly options: SimulatorOptions = {}) {
    this.#myId = options.myUserId ?? 777_001;
    this.#chats = options.chats ?? [];
  }

  get sentMessages(): readonly TdObject[] {
    return this.#sent;
  }

  get chatActions(): readonly TdObject[] {
    return this.#actions;
  }

  get authorizationState(): string {
    return this.#authorization.state;
  }

  /** The chats the simulated account knows about; demo mode seeds these. */
  addChat(chat: SimulatorChat): number {
    const id = chat.id ?? ++this.#chatId;
    const existing = this.#chats.find((candidate) => candidate.id === id);
    if (existing) Object.assign(existing, chat);
    else this.#chats.push({ ...chat, id });
    return id;
  }

  async start(): Promise<void> {
    this.stopped = false;
    // Real TDLib says nothing until `setTdlibParameters` arrives — it has no idea
    // which database to open before that. The state stays `started` on purpose.
    this.#authorization = { state: 'started' };
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.#handlers.clear();
    this.#emit({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateClosing' } });
  }

  onReceive(handler: (raw: string) => void): () => void {
    this.#handlers.add(handler);
    return () => this.#handlers.delete(handler);
  }

  /** The simulator answers `execute` for the handful of synchronous methods. */
  execute(serialized: string): string | null {
    const request = JSON.parse(serialized) as TdObject;
    switch (request['@type']) {
      case 'getApplicationPath':
        return JSON.stringify({ '@type': 'text', value: process.cwd() });
      case 'getOption':
        return JSON.stringify(this.#option(String(request.name ?? '')));
      case 'getLanguagePackString':
        return JSON.stringify({ '@type': 'error', code: 400, message: 'not modelled by the simulator' });
      case 'setLogStream':
      case 'setLogVerbosityLevel':
        return JSON.stringify({ '@type': 'ok' });
      default:
        return null;
    }
  }

  send(serialized: string): void {
    const request = JSON.parse(serialized) as TdObject;
    // Real TDLib answers on its own thread; keep the async shape so callers
    // cannot accidentally rely on synchronous completion.
    setTimeout(() => this.#handle(request), 0);
  }

  /** Force the next request of `type` to fail; used to exercise retry logic. */
  failNext(type: string, code: number, message: string): void {
    this.#scripted.push({ type, code, message });
  }

  /** Inject an inbound Telegram message (the "someone texted us" path). */
  injectIncoming(input: {
    chatId: number;
    text?: string;
    senderName?: string;
    senderUserId?: number;
    isOutgoing?: boolean;
    photo?: boolean;
    voice?: { duration: number; bytes?: number };
    mediaMessage?: TdObject;
  }): TdObject {
    const id = ++this.#messageId;
    const content: TdObject = input.mediaMessage
      ? input.mediaMessage
      : input.photo
        ? {
            '@type': 'messagePhoto',
            photo: {
              '@type': 'photo',
              has_sticker: false,
              sizes: [
                {
                  '@type': 'photoSize',
                  photo_size: { '@type': 'file', id: ++this.#fileId, size: 20_000, expected_size: 20_000 },
                  type: 'x',
                  width: 1280,
                  height: 720,
                },
              ],
              caption: { '@type': 'formattedText', text: input.text ?? '', entities: [] },
            },
          }
        : input.voice
          ? {
              '@type': 'messageVoiceNote',
              voice_note: {
                '@type': 'voiceNote',
                duration: input.voice.duration,
                waveform: Buffer.from(new Array(51).fill(40)).toString('base64'),
                mime_type: 'audio/ogg',
                voice: {
                  '@type': 'file',
                  id: ++this.#fileId,
                  size: input.voice.bytes ?? 12_000,
                  expected_size: input.voice.bytes ?? 12_000,
                },
              },
              caption: { '@type': 'formattedText', text: '', entities: [] },
            }
          : {
              '@type': 'messageText',
              text: { '@type': 'formattedText', text: input.text ?? '', entities: [] },
              link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: false },
            };

    const message: TdObject = {
      '@type': 'message',
      id,
      message_thread_id: null,
      sender_id: input.isOutgoing
        ? { '@type': 'messageSenderUser', user_id: this.#myId }
        : { '@type': 'messageSenderUser', user_id: input.senderUserId ?? 555 },
      chat_id: input.chatId,
      date: Math.floor(Date.now() / 1000),
      content,
      is_outgoing: input.isOutgoing ?? false,
      can_be_edited: input.isOutgoing ?? false,
      can_be_forwarded: true,
      can_send_reply: true,
      sender_name: input.senderName ?? (input.isOutgoing ? null : 'Simulated Peer'),
    };
    this.#emit({ '@type': 'updateNewMessage', message, out: false });
    return message;
  }

  /** Mark our side as read by the peer, producing an inbound read event. */
  injectPeerRead(chatId: number, maxMessageId: number): void {
    this.#emit({
      '@type': 'updateReadInboxChatHistory',
      chat_id: chatId,
      max_read_message_id: maxMessageId,
      is_expiring: false,
    });
  }

  #handle(request: TdObject): void {
    if (this.stopped) return;
    const type = request['@type'];
    const extra = request['@extra'] as string | undefined;
    const reply = (event: TdObject): void => {
      this.#emit(extra ? { ...event, '@extra': extra } : event);
    };
    const fail = (code: number, message: string): void =>
      reply({ '@type': 'error', code, message, '@extra': extra });

    // Scripted failures come first so a test can force FLOOD_WAIT_ / 500s
    // without contorting the request it sends.
    const scriptedIndex = this.#scripted.findIndex((entry) => entry.type === type);
    if (scriptedIndex >= 0) {
      const scripted = this.#scripted.splice(scriptedIndex, 1)[0]!;
      fail(scripted.code, scripted.message);
      return;
    }

    try {
      switch (type) {
        case 'setTdlibParameters': {
          if (request.database_encryption_key != null &&
              typeof request.database_encryption_key !== 'string') {
            fail(400, 'DATABASE_ENCRYPTION_KEY_INVALID');
            return;
          }
          reply({ '@type': 'ok' });
          this.#authorization = { state: 'wait_phone' };
          this.#emit({
            '@type': 'updateAuthorizationState',
            authorization_state: { '@type': 'authorizationStateWaitPhoneNumber' },
          });
          return;
        }

        case 'setAuthenticationPhoneNumber': {
          if (typeof request.phone_number !== 'string' || !request.phone_number ||
              !Object.hasOwn(request, 'settings') ||
              (request.settings !== null &&
                (typeof request.settings !== 'object' ||
                 (request.settings as TdObject)['@type'] !== 'phoneNumberAuthenticationSettings')) ||
              'allow_flash_call' in request || 'is_current_phone_number' in request) {
            fail(400, 'PHONE_SETTINGS_INVALID');
            return;
          }
          this.#authorization = { state: 'wait_code', phone: request.phone_number };
          this.#emit({
            '@type': 'updateAuthorizationState',
            authorization_state: {
              '@type': 'authorizationStateWaitCode',
              phone_code_info: {
                '@type': 'phoneCodeInfo',
                phone_number: this.#authorization.phone,
                type: { '@type': 'authenticationCodeTypeSms', length: 5 },
                length: 5,
              },
            },
          });
          reply({ '@type': 'ok' });
          return;
        }

        case 'checkAuthenticationCode': {
          const expected = this.options.phoneCode ?? '12345';
          if (String(request.code ?? '').replace(/\D/g, '') !== expected) {
            fail(400, 'PHONE_CODE_INVALID');
            return;
          }
          if (this.options.password) {
            this.#authorization = { ...this.#authorization, state: 'wait_password' };
            this.#emit({
              '@type': 'updateAuthorizationState',
              authorization_state: {
                '@type': 'authorizationStateWaitPassword',
                password_hint: 'simulator',
                has_email: false,
                is_recovery_code_allowed: false,
              },
            });
            reply({ '@type': 'ok' });
            return;
          }
          this.#ready();
          reply({ '@type': 'ok' });
          return;
        }

        case 'checkAuthenticationPassword': {
          if (String(request.password ?? '') !== (this.options.password ?? '')) {
            fail(400, 'PASSWORD_HASH_INVALID');
            return;
          }
          this.#ready();
          reply({ '@type': 'ok' });
          return;
        }

        case 'logOut':
          reply({ '@type': 'ok' });
          this.#authorization = { state: 'closed' };
          this.#emit({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateClosed' } });
          return;

        case 'getMe':
          reply({
            '@type': 'user',
            id: this.#myId,
            first_name: 'MessengerX',
            last_name: 'Simulator',
            username: 'messengerx_sim',
            phone_number: this.#authorization.phone ?? '+10000000000',
            type: { '@type': 'userTypeRegular' },
            status: { '@type': 'userStatusRecently' },
            is_contact: true,
            have_access_hash: true,
          });
          return;

        case 'getOption':
          reply(this.#option(String(request.name ?? '')));
          return;

        case 'getChats':
          reply({
            '@type': 'chats',
            chat_ids: this.#chats.map((chat) => chat.id),
          });
          return;

        case 'searchChatsOnServer':
        case 'searchChats':
          reply({
            '@type': 'chats',
            chat_ids: this.#chats
              .filter((chat) =>
                request.query ? chat.title?.toLowerCase().includes(String(request.query).toLowerCase()) : true,
              )
              .map((chat) => chat.id),
          });
          return;

        case 'getChat': {
          const chat = this.#findChat(Number(request.chat_id));
          if (!chat) {
            fail(400, 'CHAT_NOT_FOUND');
            return;
          }
          reply(this.#chatObject(chat));
          return;
        }

        case 'createPrivateChat': {
          // Saved Messages is a private chat with the authorised account.
          const id = Number(request.user_id);
          if (this.#authorization.state !== 'ready' || id !== this.#myId) {
            fail(400, 'PEER_ID_INVALID');
            return;
          }
          this.addChat({ id, title: 'Saved Messages', type: 'private', peerUserId: id });
          reply(this.#chatObject(this.#findChat(id)!));
          return;
        }

        case 'getChatHistory': {
          const from = Number(request.from_message_id ?? this.#messageId);
          reply({
            '@type': 'messages',
            messages: this.#sent
              .filter((message) => message.chat_id === Number(request.chat_id) && Number(message.id) <= from)
              .slice(-Math.max(1, Number(request.limit ?? 20))),
          });
          return;
        }

        case 'openChat':
          reply({ '@type': 'ok' });
          return;

        case 'closeChat':
          reply({ '@type': 'ok' });
          return;

        case 'createNewBasicGroupChat': {
          const id = this.addChat({
            id: ++this.#chatId,
            title: String(request.title ?? 'Simulated group'),
            type: 'basic_group',
          });
          reply(this.#chatObject(this.#chats.find((chat) => chat.id === id)!));
          return;
        }

        case 'sendMessage': {
          if (this.#authorization.state !== 'ready') {
            fail(407, 'AUTH_WRITE_REQUIRED');
            return;
          }
          // Fail if the bridge drifts from the pinned TDLib td_api.tl; the real
          // JSON client does not accept `messageSendingOptions` or `priority`.
          const options = request.options as TdObject | undefined;
          if (options && (options['@type'] !== 'messageSendOptions' || 'priority' in options ||
                          'allow_sending_without_reply' in options)) {
            fail(400, 'MESSAGE_SEND_OPTIONS_INVALID');
            return;
          }
          const chatId = Number(request.chat_id);
          const id = ++this.#messageId;
          const sendingId = Number(
            ((request.options as TdObject | undefined)?.sending_id ?? request.sending_id ?? 0),
          );
          const message: TdObject = {
            '@type': 'message',
            id,
            sender_id: { '@type': 'messageSenderUser', user_id: this.#myId },
            chat_id: chatId,
            date: Math.floor(Date.now() / 1000),
            content: request.input_message_content,
            is_outgoing: true,
            sending_state: { '@type': 'messageSendingStatePending', sending_id: sendingId || null },
            // Kept on the message as well so a test can assert the bridge correlated
            // its outbox id with what it handed TDLib as `sending_id`.
            sending_id: sendingId || null,
            reply_to_message_id: (request.reply_to as TdObject | undefined)?.message_id ?? null,
          };
          reply({ ...message, '@type': 'message' });
          // The echo arrives as a normal update, exactly like the real client, so
          // the bridge's dedupe/echo reconciliation is exercised rather than
          // short-circuited by a shortcut in the simulator.
          setTimeout(() => {
            if (this.stopped) return;
            this.#emit({ '@type': 'updateNewMessage', message: { ...message, sending_state: undefined } });
            this.#emit({ '@type': 'updateMessageSendAcknowledged', chat_id: chatId, message_id: id });
          }, 0);
          if (this.options.deliveryDelayMs) {
            setTimeout(() => {
              if (this.stopped) return;
              this.injectPeerRead(chatId, id);
            }, this.options.deliveryDelayMs);
          }
          this.#sent.push(message);
          return;
        }

        case 'editMessageText':
          reply({ '@type': 'ok' });
          this.#emit({
            '@type': 'updateMessageContent',
            chat_id: Number(request.chat_id),
            message_id: Number(request.message_id),
            new_content: request.input_message_content,
          });
          return;

        case 'deleteMessages':
          reply({ '@type': 'ok' });
          this.#emit({
            '@type': 'updateDeleteMessages',
            chat_id: Number(request.chat_id),
            message_ids: (request.message_ids as number[] | undefined) ?? [],
            revoke: request.revoke === true,
          });
          return;

        case 'sendMessageRead':
          reply({ '@type': 'ok' });
          this.#readCursors.set(
            Number(request.chat_id),
            Math.max(this.#readCursors.get(Number(request.chat_id)) ?? 0, ...(request.message_ids as number[]) ?? [0]),
          );
          return;

        case 'viewMessages':
          reply({ '@type': 'ok' });
          for (const view of (request.messages as TdObject[] | undefined) ?? []) {
            if (view['@type'] !== 'messageViewers') continue;
            this.#readCursors.set(
              Number(request.chat_id),
              Math.max(this.#readCursors.get(Number(request.chat_id)) ?? 0, Number(view.max_read_message_id ?? 0)),
            );
          }
          return;

        case 'sendChatAction':
          reply({ '@type': 'ok' });
          this.#actions.push(request);
          return;

        case 'getFile': {
          const fileId = Number(request.file_id);
          reply({
            '@type': 'file',
            id: fileId,
            size: 1024,
            expected_size: 1024,
            local: {
              '@type': 'localFile',
              path: `${process.env.TMPDIR ?? '/tmp'}/messengerx-sim-${fileId}.bin`,
              is_downloaded_now: false,
              is_downloading_active: false,
              downloaded_size: 0,
            },
            remote: { '@type': 'remoteFile', id: `rem-${fileId}`, is_downloading_active: false, downloaded_size: 0 },
          });
          return;
        }

        case 'downloadFile': {
          reply({ '@type': 'ok' });
          setTimeout(() => {
            if (this.stopped) return;
            this.#emit({
              '@type': 'updateFile',
              file: {
                '@type': 'file',
                id: Number(request.file_id),
                size: 1024,
                expected_size: 1024,
                local: {
                  '@type': 'localFile',
                  path: `${process.env.TMPDIR ?? '/tmp'}/messengerx-sim-${Number(request.file_id)}.bin`,
                  is_downloaded_now: true,
                  downloaded_size: 1024,
                },
              },
            });
          }, 0);
          return;
        }

        case 'cancelDownloadFile':
          reply({ '@type': 'ok' });
          return;

        case 'setNotificationSettings':
        case 'setChatNotificationSettings':
        case 'removeChatFromList':
        case 'setChatMarkedAsUnread':
          reply({ '@type': 'ok' });
          return;

        default:
          fail(404, `method ${String(type)} is not modelled by the simulator`);
      }
    } catch (error) {
      fail(500, `simulator fault: ${(error as Error).message}`);
    }
  }

  #ready(): void {
    this.#authorization = { ...this.#authorization, state: 'ready' };
    this.#emit({ '@type': 'updateAuthorizationState', authorization_state: { '@type': 'authorizationStateReady' } });
    this.#emit({ '@type': 'updateOption', name: 'my_id', value: { '@type': 'tdlibParametersOptionId', value: this.#myId } });
    this.#emit({ '@type': 'updateMe', user: { '@type': 'user', id: this.#myId, first_name: 'MessengerX' } });
  }

  #option(name: string): TdObject {
    if (name === 'my_id') return { '@type': 'optionValueInteger', value: this.#myId };
    if (name === 'version') return { '@type': 'optionValueString', value: 'tdlib-simulator' };
    return { '@type': 'optionValueEmpty' };
  }

  #findChat(id: number): SimulatorChat | undefined {
    return this.#chats.find((chat) => chat.id === id);
  }

  #chatObject(chat: SimulatorChat): TdObject {
    const type =
      (chat.type ?? 'private') === 'private'
        ? { '@type': 'chatTypePrivate', user_id: chat.peerUserId ?? 555 }
        : chat.type === 'basic_group'
          ? { '@type': 'chatTypeBasicGroup', basic_group_id: chat.id }
          : { '@type': 'chatTypeSupergroup', supergroup_id: chat.id };
    return {
      '@type': 'chat',
      id: chat.id,
      type,
      title: chat.title ?? chat.peerName ?? 'Simulated chat',
      unread_count: 0,
      unread_count_from_message_id_to_mark_read: 0,
      last_message: { '@type': 'message', id: this.#messageId },
      is_marked_as_unread: false,
      is_slow_mode: false,
    };
  }

  #emit(event: TdObject): void {
    const raw = JSON.stringify(event);
    for (const handler of this.#handlers) handler(raw);
  }

}
