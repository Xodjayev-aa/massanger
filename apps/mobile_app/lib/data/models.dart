import '../core/formatting.dart';
import '../core/waveform.dart';

/// Mirrors of the database enums. Unknown values must not crash a client that is
/// one migration behind the server, so every parser falls back rather than throwing.
enum MessageKind {
  text,
  image,
  voice,
  system;

  static MessageKind parse(Object? value) => MessageKind.values.firstWhere(
        (kind) => kind.wire == value,
        orElse: () => MessageKind.text,
      );

  String get wire => name;
}

/// `public.delivery_state`. Ordered: `rank` is what the triggers use to make sure a
/// late `sent` can never overwrite a `read`.
enum DeliveryState {
  pending,
  sending,
  sent,
  delivered,
  read,
  failed;

  static DeliveryState parse(Object? value) => DeliveryState.values.firstWhere(
        (state) => state.wire == value,
        orElse: () => DeliveryState.pending,
      );

  String get wire => name;

  bool get isInFlight => this == DeliveryState.pending || this == DeliveryState.sending;

  bool get isFailed => this == DeliveryState.failed;

  /// Tick count for the bubble: 1 grey, 2 grey, 2 blue, plus the failed "!".
  int get ticks => switch (this) {
        DeliveryState.pending || DeliveryState.sending => 1,
        DeliveryState.sent || DeliveryState.delivered => 2,
        DeliveryState.read => 2,
        DeliveryState.failed => 0,
      };

  bool get ticksAreBlue => this == DeliveryState.read;
}

enum ChatKind {
  direct,
  group;

  static ChatKind parse(Object? value) => ChatKind.values.firstWhere(
        (kind) => kind.wire == value,
        orElse: () => ChatKind.direct,
      );

  String get wire => name;
}

/// One attachment (image or voice note) as it is stored in `messages.media`.
sealed class MessageMedia {
  const MessageMedia();

  /// Round-trips through `messages.media` unchanged: what the composer uploads is
  /// what `validate_message_media` accepts, and what a retry resends.
  Map<String, Object?> toMap();

  String? get storagePath;

  String? get bucket;

  bool get isExternal => storagePath == null;

  static MessageMedia? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    return switch (map['kind']) {
      'voice' => VoiceMedia.fromMap(map),
      'image' => ImageMedia.fromMap(map),
      _ => map['duration_ms'] != null ? VoiceMedia.fromMap(map) : ImageMedia.fromMap(map),
    };
  }
}

final class ImageMedia extends MessageMedia {
  const ImageMedia({
    this.bucket,
    this.storagePath,
    this.url,
    this.mime = 'image/jpeg',
    this.width = 0,
    this.height = 0,
    this.sizeBytes = 0,
    this.blurhash,
    this.caption,
  });

  @override
  final String? bucket;
  @override
  final String? storagePath;
  final String? url;
  final String mime;
  final int width;
  final int height;
  final int sizeBytes;
  final String? blurhash;
  final String? caption;

  factory ImageMedia.fromMap(Map<String, dynamic> map) => ImageMedia(
        bucket: map['bucket'] as String?,
        storagePath: map['path'] as String?,
        url: map['url'] as String?,
        mime: asString(map['mime'], fallback: 'image/jpeg'),
        width: asInt(map['width']),
        height: asInt(map['height']),
        sizeBytes: asInt(map['size_bytes']),
        blurhash: map['blurhash'] as String?,
        caption: map['caption'] as String?,
      );

  double get aspectRatio => width <= 0 || height <= 0 ? 1.0 : width / height;

  @override
  Map<String, Object?> toMap() => {
        'kind': 'image',
        'bucket': bucket,
        'path': storagePath,
        if (url != null) 'url': url,
        'mime': mime,
        'width': width,
        'height': height,
        'size_bytes': sizeBytes,
        if (blurhash != null) 'blurhash': blurhash,
        if (caption != null && caption!.isNotEmpty) 'caption': caption,
      };
}

final class VoiceMedia extends MessageMedia {
  const VoiceMedia({
    this.bucket,
    this.storagePath,
    this.url,
    this.mime = 'audio/wav',
    this.duration = Duration.zero,
    this.sizeBytes = 0,
    this.waveform = const <int>[],
    this.transcript,
  });

  @override
  final String? bucket;
  @override
  final String? storagePath;
  final String? url;
  final String mime;
  final Duration duration;
  final int sizeBytes;

  /// 64 bars, 0..100, exactly as the column check requires.
  final List<int> waveform;
  final String? transcript;

  factory VoiceMedia.fromMap(Map<String, dynamic> map) => VoiceMedia(
        bucket: map['bucket'] as String?,
        storagePath: map['path'] as String?,
        url: map['url'] as String?,
        mime: asString(map['mime'], fallback: 'audio/wav'),
        duration: Duration(milliseconds: asInt(map['duration_ms'])),
        sizeBytes: asInt(map['size_bytes']),
        waveform: Waveform.sanitize(map['waveform']),
        transcript: map['text_transcript'] as String?,
      );

  @override
  Map<String, Object?> toMap() => {
        'kind': 'voice',
        'bucket': bucket,
        'path': storagePath,
        if (url != null) 'url': url,
        'mime': mime,
        'duration_ms': duration.inMilliseconds,
        'size_bytes': sizeBytes,
        if (waveform.length == Waveform.buckets) 'waveform': waveform,
        if (transcript != null && transcript!.isNotEmpty) 'text_transcript': transcript,
      };
}

final class MessageItem {
  const MessageItem({
    required this.id,
    required this.chatId,
    required this.kind,
    required this.state,
    required this.isMine,
    required this.senderId,
    required this.senderName,
    this.body,
    this.media,
    this.senderAvatarPath,
    this.createdAt,
    this.sentAt,
    this.deliveredAt,
    this.readAt,
    this.editedAt,
    this.failureCode,
    this.failureReason,
    this.replyToId,
    this.replySenderName,
    this.replyBody,
    this.source = 'app',
    this.clientMessageId,
    this.tgMessageId,
    this.syncedToTelegramAt,
    this.isLocal = false,
  });

  final String id;
  final String chatId;
  final MessageKind kind;
  final DeliveryState state;
  final bool isMine;
  final String? senderId;
  final String senderName;
  final String? body;
  final MessageMedia? media;
  final String? senderAvatarPath;
  final DateTime? createdAt;
  final DateTime? sentAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final DateTime? editedAt;
  final String? failureCode;
  final String? failureReason;
  final String? replyToId;
  final String? replySenderName;
  final String? replyBody;

  /// `app` or `telegram` — drives the small origin marker on mirrored bubbles.
  final String source;

  /// Our idempotency key; equals [id] while the message is only local.
  final String? clientMessageId;
  final String? tgMessageId;
  final DateTime? syncedToTelegramAt;

  /// True until the server row replaces it. Local bubbles are never counted as
  /// "read" and cannot be replied to by id (the row does not exist yet).
  final bool isLocal;

  bool get isMirroredFromTelegram => source == 'telegram';

  bool get isTelegramDelivered => syncedToTelegramAt != null;

  DateTime get timestamp => sentAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  String? get failureText => state.isFailed ? ChatFormatting.failureLabel(failureCode ?? '', failureReason) : null;

  factory MessageItem.fromMap(Map<String, dynamic> map, {required String currentUserId}) {
    final senderId = map['sender_id'] as String?;
    final kind = MessageKind.parse(map['kind']);
    final media = MessageMedia.fromMap(map['media']);
    final replyBody = map['reply_body'] as String?;
    return MessageItem(
      id: '${map['id']}',
      chatId: '${map['chat_id'] ?? map['chatId']}',
      kind: kind,
      // `delivery_status` is what the ticks show; `chat_feed` also folds the
      // telegram sync marker into it, so a mirrored row is never stuck at `pending`.
      state: DeliveryState.parse(map['delivery_status']),
      // An attachment's caption lives in `body` too; the voice and photo renderers
      // draw it under the player so both stay in one column of the row.
      body: map['body'] as String?,
      media: media,
      isMine: map['is_mine'] == true || (map['is_mine'] == null && senderId != null && senderId == currentUserId),
      senderId: senderId,
      senderName: asString(map['sender_name'], fallback: isSelf(map, currentUserId) ? 'You' : 'Telegram'),
      senderAvatarPath: map['sender_avatar_path'] as String?,
      createdAt: parseTimestamp(map['created_at']),
      sentAt: parseTimestamp(map['sent_at']),
      deliveredAt: parseTimestamp(map['delivered_at']),
      readAt: parseTimestamp(map['read_at']),
      editedAt: parseTimestamp(map['edited_at']),
      failureCode: map['failure_code'] as String?,
      failureReason: map['failure_reason'] as String?,
      replyToId: map['reply_to_id'] as String?,
      replySenderName: map['reply_sender_name'] as String?,
      replyBody: replyBody,
      source: asString(map['source'], fallback: 'app'),
      clientMessageId: map['client_message_id'] as String?,
      tgMessageId: map['tg_message_id'] == null ? null : '${map['tg_message_id']}',
      syncedToTelegramAt: parseTimestamp(map['synced_to_telegram_at']),
    );
  }

  static bool isSelf(Map<String, dynamic> map, String currentUserId) =>
      map['sender_id'] != null && '${map['sender_id']}' == currentUserId;

  /// A pending bubble the composer owns, keyed by `client_message_id` so the
  /// arriving server row can be matched without comparing text.
  factory MessageItem.local({
    required String chatId,
    required MessageKind kind,
    required String clientMessageId,
    required String senderName,
    String? body,
    MessageMedia? media,
    String? replyToId,
    String? replySenderName,
    String? replyBody,
  }) =>
      MessageItem(
        id: clientMessageId,
        chatId: chatId,
        kind: kind,
        state: DeliveryState.pending,
        isMine: true,
        senderId: null,
        senderName: senderName,
        body: body,
        media: media,
        createdAt: DateTime.now(),
        replyToId: replyToId,
        replySenderName: replySenderName,
        replyBody: replyBody,
        clientMessageId: clientMessageId,
        isLocal: true,
      );

  MessageItem copyWith({DeliveryState? state, bool? isLocal, DateTime? syncedToTelegramAt}) => MessageItem(
        id: id,
        chatId: chatId,
        kind: kind,
        state: state ?? this.state,
        isMine: isMine,
        senderId: senderId,
        senderName: senderName,
        body: body,
        media: media,
        senderAvatarPath: senderAvatarPath,
        createdAt: createdAt,
        sentAt: sentAt,
        deliveredAt: deliveredAt,
        readAt: readAt,
        editedAt: editedAt,
        failureCode: failureCode,
        failureReason: failureReason,
        replyToId: replyToId,
        replySenderName: replySenderName,
        replyBody: replyBody,
        source: source,
        clientMessageId: clientMessageId,
        tgMessageId: tgMessageId,
        syncedToTelegramAt: syncedToTelegramAt ?? this.syncedToTelegramAt,
        isLocal: isLocal ?? this.isLocal,
      );

  /// Text shown in the chat list and in reply quotes.
  String get preview {
    switch (kind) {
      case MessageKind.image:
        final caption = body;
        return caption == null || caption.isEmpty ? 'Photo' : 'Photo: $caption';
      case MessageKind.voice:
        final attached = media;
        if (attached is VoiceMedia) return 'Voice note (${ChatFormatting.duration(attached.duration)})';
        return 'Voice note';
      case MessageKind.system:
        return body ?? '';
      case MessageKind.text:
        return body ?? '';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MessageItem && other.id == id && other.state == state && other.body == body && other.media == media;

  @override
  int get hashCode => Object.hash(id, state, body);
}

final class ChatSummary {
  const ChatSummary({
    required this.chatId,
    required this.kind,
    this.title,
    this.avatarPath,
    this.avatarExternalUrl,
    this.isTelegramMirror = false,
    this.tgChatId,
    this.tgChatType,
    this.syncDirection,
    this.lastMessageId,
    this.lastMessageAt,
    this.previewBody,
    this.previewSender,
    this.previewKind,
    this.previewState,
    this.previewIsMine = false,
    this.unreadCount = 0,
    this.isMuted = false,
    this.peerId,
    this.peerUsername,
    this.peerDisplayName,
    this.peerAvatarPath,
    this.peerIsOnline = false,
    this.telegramAuthState,
    this.telegramUsername,
  });

  final String chatId;
  final ChatKind kind;
  final String? title;
  final String? avatarPath;
  final String? avatarExternalUrl;
  final bool isTelegramMirror;
  final String? tgChatId;
  final String? tgChatType;
  final String? syncDirection;
  final String? lastMessageId;
  final DateTime? lastMessageAt;
  final String? previewBody;
  final String? previewSender;
  final String? previewKind;
  final String? previewState;
  final bool previewIsMine;
  final int unreadCount;
  final bool isMuted;
  final String? peerId;
  final String? peerUsername;
  final String? peerDisplayName;
  final String? peerAvatarPath;
  final bool peerIsOnline;
  final String? telegramAuthState;
  final String? telegramUsername;

  String get displayName => switch (kind) {
        ChatKind.group => title ?? 'Group',
        ChatKind.direct => peerDisplayName ?? peerUsername ?? 'Direct chat',
      };

  String? get avatar => avatarPath ?? avatarExternalUrl ?? peerAvatarPath;

  bool get isTelegramOnly => isTelegramMirror;

  /// True when the account backing this mirrored chat cannot currently send: the
  /// composer shows the reason instead of a disabled button.
  bool get telegramNeedsAuth => switch (telegramAuthState) {
        'awaiting_phone' || 'awaiting_code' || 'awaiting_password' || 'awaiting_registration' || 'needs_reauth' || 'failed' =>
          true,
        _ => false,
      };

  factory ChatSummary.fromMap(Map<String, dynamic> map) => ChatSummary(
        chatId: '${map['chat_id']}',
        kind: ChatKind.parse(map['kind']),
        title: map['title'] as String?,
        avatarPath: map['avatar_path'] as String?,
        avatarExternalUrl: map['avatar_external_url'] as String?,
        isTelegramMirror: asBool(map['is_telegram_mirror']),
        tgChatId: map['tg_chat_id'] == null ? null : '${map['tg_chat_id']}',
        tgChatType: map['tg_chat_type'] as String?,
        syncDirection: map['sync_direction'] as String?,
        lastMessageId: map['last_message_id'] as String?,
        lastMessageAt: parseTimestamp(map['last_message_at']),
        previewBody: map['preview_body'] as String?,
        previewSender: map['preview_sender'] as String?,
        previewKind: map['preview_kind'] as String?,
        previewState: map['preview_state'] as String?,
        previewIsMine: asBool(map['preview_is_mine']),
        unreadCount: asInt(map['unread_count']),
        isMuted: asBool(map['is_muted']),
        peerId: map['peer_id'] as String?,
        peerUsername: map['peer_username'] as String?,
        peerDisplayName: map['peer_display_name'] as String?,
        peerAvatarPath: map['peer_avatar_path'] as String?,
        peerIsOnline: asBool(map['peer_is_online']),
        telegramAuthState: map['telegram_auth_state'] as String?,
        telegramUsername: map['telegram_username'] as String?,
      );

  ChatSummary withUnread(int count) => ChatSummary(
        chatId: chatId,
        kind: kind,
        title: title,
        avatarPath: avatarPath,
        avatarExternalUrl: avatarExternalUrl,
        isTelegramMirror: isTelegramMirror,
        tgChatId: tgChatId,
        tgChatType: tgChatType,
        syncDirection: syncDirection,
        lastMessageId: lastMessageId,
        lastMessageAt: lastMessageAt,
        previewBody: previewBody,
        previewSender: previewSender,
        previewKind: previewKind,
        previewState: previewState,
        previewIsMine: previewIsMine,
        unreadCount: count,
        isMuted: isMuted,
        peerId: peerId,
        peerUsername: peerUsername,
        peerDisplayName: peerDisplayName,
        peerAvatarPath: peerAvatarPath,
        peerIsOnline: peerIsOnline,
        telegramAuthState: telegramAuthState,
        telegramUsername: telegramUsername,
      );

  String get subtitle {
    final prefix = previewIsMine ? 'You: ' : (kind == ChatKind.group && previewSender != null ? '$previewSender: ' : '');
    final text = previewBody ?? '';
    return text.isEmpty ? 'No messages yet' : '$prefix$text';
  }
}

final class DirectoryEntry {
  const DirectoryEntry({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarPath,
    this.avatarExternalUrl,
    this.bio,
    this.telegramUsername,
    this.isOnline = false,
    this.lastSeenAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarPath;
  final String? avatarExternalUrl;
  final String? bio;
  final String? telegramUsername;
  final bool isOnline;
  final DateTime? lastSeenAt;

  String? get avatar => avatarPath ?? avatarExternalUrl;

  factory DirectoryEntry.fromMap(Map<String, dynamic> map) => DirectoryEntry(
        id: '${map['id']}',
        username: asString(map['username']),
        displayName: asString(map['display_name'], fallback: asString(map['username'])),
        avatarPath: map['avatar_path'] as String?,
        avatarExternalUrl: map['avatar_external_url'] as String?,
        bio: map['bio'] as String?,
        telegramUsername: map['telegram_username'] as String?,
        isOnline: asBool(map['is_online']),
        lastSeenAt: parseTimestamp(map['last_seen_at']),
      );
}

/// Own profile, including the gated access state the age check writes.
final class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.accessState,
    this.avatarPath,
    this.avatarExternalUrl,
    this.bio = '',
    this.phoneE164,
    this.telegramUsername,
    this.googleEmail,
    this.googleAccountCreatedAt,
    this.googleAccountAgeDays,
    this.eligibilityVerifiedAt,
    this.eligibilityMethod,
    this.eligibilityAttempts = 0,
    this.accessStateReason,
    this.lastSeenAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String accessState;
  final String? avatarPath;
  final String? avatarExternalUrl;
  final String bio;
  final String? phoneE164;
  final String? telegramUsername;
  final String? googleEmail;
  final DateTime? googleAccountCreatedAt;
  final int? googleAccountAgeDays;
  final DateTime? eligibilityVerifiedAt;
  final String? eligibilityMethod;
  final int eligibilityAttempts;
  final String? accessStateReason;
  final DateTime? lastSeenAt;

  bool get isGated => accessState == 'pending_verification' || accessState == 'restricted';

  bool get isBlocked => accessState == 'restricted' || accessState == 'banned';

  String? get avatar => avatarPath ?? avatarExternalUrl;

  factory AccountProfile.fromMap(Map<String, dynamic> map) => AccountProfile(
        id: '${map['id']}',
        username: asString(map['username']),
        displayName: asString(map['display_name']),
        accessState: asString(map['access_state'], fallback: 'pending_verification'),
        avatarPath: map['avatar_path'] as String?,
        avatarExternalUrl: map['avatar_external_url'] as String?,
        bio: asString(map['bio']),
        phoneE164: map['phone_e164'] as String?,
        telegramUsername: map['telegram_username'] as String?,
        googleEmail: map['google_email'] as String?,
        googleAccountCreatedAt: parseTimestamp(map['google_account_created_at']),
        googleAccountAgeDays: map['google_account_age_days'] == null ? null : asInt(map['google_account_age_days']),
        eligibilityVerifiedAt: parseTimestamp(map['eligibility_verified_at']),
        eligibilityMethod: map['eligibility_method'] as String?,
        eligibilityAttempts: asInt(map['eligibility_attempts']),
        accessStateReason: map['access_state_reason'] as String?,
        lastSeenAt: parseTimestamp(map['last_seen_at']),
      );
}

/// `telegram_link_state()` → the whole Telegram panel in one read.
final class TelegramStatus {
  const TelegramStatus({
    this.authState = 'unlinked',
    this.note,
    this.tgUserId,
    this.tgUsername,
    this.displayName,
    this.syncDirection = 'both',
    this.autoDownloadVoice = true,
    this.autoDownloadMedia = true,
    this.mirrorToApp = true,
    this.linkedAt,
    this.lastSyncAt,
    this.lastError,
    this.mirroredChats = 0,
    this.pendingRequest,
  });

  final String authState;
  final String? note;
  final String? tgUserId;
  final String? tgUsername;
  final String? displayName;
  final String syncDirection;
  final bool autoDownloadVoice;
  final bool autoDownloadMedia;
  final bool mirrorToApp;
  final DateTime? linkedAt;
  final DateTime? lastSyncAt;
  final String? lastError;
  final int mirroredChats;
  final LinkRequest? pendingRequest;

  bool get isLinked => authState == 'linked' || authState == 'syncing';

  bool get needsUserInput => switch (authState) {
        'awaiting_phone' || 'awaiting_code' || 'awaiting_password' || 'awaiting_registration' || 'needs_reauth' =>
          true,
        _ => false,
      };

  String get headline => switch (authState) {
        'linked' => 'Connected${tgUsername == null ? '' : ' as @$tgUsername'}',
        'syncing' => 'Syncing',
        'needs_reauth' => 'Telegram sign-in needed again',
        'revoked' => 'Session revoked on Telegram',
        'failed' => 'Last attempt failed',
        'unlinked' => 'Not linked',
        _ => 'Waiting for you',
      };

  factory TelegramStatus.fromMap(Map<String, dynamic> map) => TelegramStatus(
        authState: asString(map['auth_state'], fallback: 'unlinked'),
        note: map['note'] as String?,
        tgUserId: map['tg_user_id'] == null ? null : '${map['tg_user_id']}',
        tgUsername: map['tg_username'] as String?,
        displayName: map['display_name'] as String?,
        syncDirection: asString(map['sync_direction'], fallback: 'both'),
        autoDownloadVoice: map['auto_download_voice'] == null || asBool(map['auto_download_voice']),
        autoDownloadMedia: map['auto_download_media'] == null || asBool(map['auto_download_media']),
        mirrorToApp: map['mirror_to_app'] == null || asBool(map['mirror_to_app']),
        linkedAt: parseTimestamp(map['linked_at']),
        lastSyncAt: parseTimestamp(map['last_sync_at']),
        lastError: map['last_error'] as String?,
        mirroredChats: asInt(map['mirrored_chats']),
        pendingRequest: map['pending_request'] is Map
            ? LinkRequest.fromMap(Map<String, dynamic>.from(map['pending_request'] as Map))
            : null,
      );
}

final class LinkRequest {
  const LinkRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.step,
    this.qrCode,
    this.error,
    this.expiresAt,
  });

  final String id;
  final String kind;
  final String status;
  final String step;
  final String? qrCode;
  final String? error;
  final DateTime? expiresAt;

  bool get isAwaitingUser => status == 'awaiting_user';

  bool get isFinished => status == 'succeeded' || status == 'failed' || status == 'expired';

  /// What the wizard should ask for right now.
  LinkPrompt get prompt => switch (step) {
        'queued' || 'awaiting_phone' => LinkPrompt.phone,
        'awaiting_code' => LinkPrompt.code,
        'awaiting_password' => LinkPrompt.password,
        'awaiting_registration' => LinkPrompt.registration,
        _ => LinkPrompt.waiting,
      };

  factory LinkRequest.fromMap(Map<String, dynamic> map) => LinkRequest(
        id: '${map['id']}',
        kind: asString(map['kind'], fallback: 'link'),
        status: asString(map['status'], fallback: 'queued'),
        step: asString(map['step'], fallback: 'queued'),
        qrCode: map['qr_code'] as String?,
        error: map['error'] as String?,
        expiresAt: parseTimestamp(map['expires_at']),
      );
}

enum LinkPrompt { phone, code, password, registration, waiting }

/// One Telegram chat the user can opt in or out of, per chat.
///
/// `chatId` is null until the mirror row exists: the bridge discovers Telegram
/// chats before the app has a matching conversation, and the UI shows those as
/// "not imported yet" instead of pretending they are empty chats.
final class MirroredChat {
  const MirroredChat({
    required this.telegramChatId,
    required this.title,
    this.chatId,
    this.direction = 'both',
    this.peerType = 'private',
    this.isMuted = false,
    this.peerUserId,
    this.lastInboundAt,
    this.lastOutboundAt,
  });

  final String? chatId;
  final String telegramChatId;
  final String title;
  final String direction;
  final String peerType;
  final bool isMuted;
  final String? peerUserId;
  final DateTime? lastInboundAt;
  final DateTime? lastOutboundAt;

  bool get isMirrored => chatId != null;

  String get directionLabel => switch (direction) {
        'off' => 'Off',
        'to_telegram' => 'App → Telegram',
        'to_app' => 'Telegram → app',
        _ => 'Two-way',
      };

  factory MirroredChat.fromMap(Map<String, dynamic> map) => MirroredChat(
        chatId: map['chat_id'] as String?,
        telegramChatId: '${map['tg_chat_id']}',
        title: asString(map['title'], fallback: 'Telegram chat'),
        direction: asString(map['sync_direction'], fallback: 'both'),
        peerType: asString(map['tg_chat_type'], fallback: 'private'),
        isMuted: asBool(map['muted']),
        peerUserId: map['peer_user_id'] == null ? null : '${map['peer_user_id']}',
        lastInboundAt: parseTimestamp(map['last_inbound_at']),
        lastOutboundAt: parseTimestamp(map['last_outbound_at']),
      );
}

/// A row of `chat_typing`: who is typing, and why the UI should show it.
final class TypingPresence {
  const TypingPresence({
    required this.userId,
    required this.source,
    required this.action,
    required this.name,
    required this.updatedAt,
  });

  final String userId;
  final String source;
  final String action;
  final String name;
  final DateTime updatedAt;

  bool get isFromTelegram => source == 'telegram';

  factory TypingPresence.fromMap(Map<String, dynamic> map) => TypingPresence(
        userId: '${map['user_id']}',
        source: asString(map['source'], fallback: 'app'),
        action: asString(map['action'], fallback: 'typing'),
        name: asString(map['name']),
        updatedAt: parseTimestamp(map['updated_at']) ?? DateTime.now(),
      );
}
