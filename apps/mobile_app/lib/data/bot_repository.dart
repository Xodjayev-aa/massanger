import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'social_models.dart';

/// A bot the caller owns, plus the installs it lives in.
class BotSummary {
  const BotSummary({
    required this.id,
    required this.profileId,
    required this.username,
    required this.displayName,
    this.about,
    this.avatarPath,
    this.inlineEnabled = true,
    this.privacyMode = true,
    this.joinGroups = true,
    this.isPublic = true,
    this.isActive = true,
    this.isVerified = false,
    this.rateLimitPerMinute = 30,
    this.installCount = 0,
    this.webhookUrl,
    this.createdAt,
  });

  final String id;
  final String profileId;
  final String username;
  final String displayName;
  final String? about;
  final String? avatarPath;
  final bool inlineEnabled;

  /// Privacy mode mirrors Telegram: with it on, the bot only sees messages that
  /// mention it or are commands addressed to it.
  final bool privacyMode;
  final bool joinGroups;
  final bool isPublic;
  final bool isActive;
  final bool isVerified;
  final int rateLimitPerMinute;
  final int installCount;
  final String? webhookUrl;
  final DateTime? createdAt;

  bool get isBotFather => username == 'botfather';

  factory BotSummary.fromMap(Map<String, dynamic> map) => BotSummary(
        id: '${map['id']}',
        profileId: '${map['profile_id'] ?? ''}',
        username: '${map['username'] ?? ''}',
        displayName: '${map['display_name'] ?? map['username'] ?? ''}',
        about: map['about'] as String?,
        avatarPath: map['avatar_path'] as String?,
        inlineEnabled: map['inline_enabled'] != false,
        privacyMode: map['privacy_mode'] != false,
        joinGroups: map['join_groups'] != false,
        isPublic: map['is_public'] != false,
        isActive: map['is_active'] != false,
        isVerified: map['is_verified'] == true,
        rateLimitPerMinute: (map['rate_limit_per_minute'] as num?)?.toInt() ?? 30,
        installCount: (map['install_count'] as num?)?.toInt() ?? 0,
        webhookUrl: map['webhook_url'] as String?,
        createdAt: map['created_at'] == null ? null : DateTime.tryParse('${map['created_at']}')?.toUtc(),
      );
}

/// One slash command a bot answers.
class BotCommand {
  const BotCommand({
    required this.command,
    required this.description,
    this.builtin,
    this.handler,
    this.permission,
    this.scope = 'all',
  });

  final String command;
  final String description;

  /// A platform builtin (`mute`, `ban`, `purge`, …) or a webhook handler.
  final String? builtin;
  final String? handler;

  /// Required community permission, when the command moderates.
  final String? permission;
  final String scope;

  String get slash => '/$command';

  factory BotCommand.fromMap(Map<String, dynamic> map) => BotCommand(
        command: '${map['command'] ?? ''}',
        description: '${map['description'] ?? ''}',
        builtin: map['builtin'] as String?,
        handler: map['handler'] as String?,
        permission: map['permission'] as String?,
        scope: '${map['scope'] ?? 'all'}',
      );
}

/// An inline query result: what a bot returns when someone types
/// `@thatbot something` in a composer.
class InlineResult {
  const InlineResult({
    required this.id,
    required this.title,
    this.description,
    this.media,
    this.body,
    this.thumbUrl,
  });

  final String id;
  final String title;
  final String? description;
  final String? body;
  final Map<String, dynamic> media;
  final String? thumbUrl;

  factory InlineResult.fromMap(Map<String, dynamic> map) => InlineResult(
        id: '${map['id']}',
        title: '${map['title'] ?? ''}',
        description: map['description'] as String?,
        body: map['body'] as String?,
        media: asMap(map['media']),
        thumbUrl: map['thumb_url'] as String?,
      );
}

/// Bots: what the owner can see about theirs, and what a chat can do with
/// somebody else's.
///
/// Creating a bot does **not** need a deploy, a dashboard or a paid plan — the
/// master bot `@BotFather` is provisioned by the migration itself, so a user
/// opens the Messages tab, talks to BotFather and gets a token for free. This
/// class drives both sides: the owner's settings and the chat's install.
class BotRepository {
  BotRepository(this._client);

  final SupabaseClient _client;

  /// The bot's own HTTP surface, for the owner's "test" panel and for external
  /// integrations. `token` is the only credential — the same call shape works
  /// from curl, from a webhook worker or from this app.
  static const String apiPath = '/functions/v1/bot-api';

  Future<List<BotSummary>> mine() async {
    try {
      final rows = await _client.rpc('bot_my');
      return asMapList(rows).map(BotSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<BotSummary>> directory({String? query, int limit = 30}) async {
    try {
      final rows = await _client.rpc('bot_directory', params: <String, Object?>{
        'p_query': query,
        'p_limit': limit,
      });
      return asMapList(rows).map(BotSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The DM with @BotFather. Created on first use, so the Messages tab can show
  /// it without a deploy step.
  Future<String> botFatherChat() async {
    try {
      final chatId = await _client.rpc('botfather_chat');
      return '$chatId';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Creates a bot. Returns the plaintext token exactly once — the database
  /// only ever stores its hash, so this value is the caller's to keep.
  Future<({String botId, String token, String username, String message})> create({
    required String username,
    required String displayName,
    String? about,
    bool inline = true,
  }) async {
    try {
      final data = asMap(await _client.rpc('bot_create', params: <String, Object?>{
        'p_username': username,
        'p_display_name': displayName,
        'p_about': about,
        'p_inline': inline,
      }));
      return (
        botId: '${data['id']}',
        token: '${data['token']}',
        username: '${data['username']}',
        message: '${data['message'] ?? ''}',
      );
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> update(
    String botId, {
    String? displayName,
    String? about,
    String? inlinePlaceholder,
    String? description,
  }) async {
    try {
      await _client.rpc('bot_update', params: <String, Object?>{
        'p_bot_id': botId,
        'p_display_name': displayName,
        'p_about': about,
        'p_inline_placeholder': inlinePlaceholder,
        'p_description': description,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Issues a new token and invalidates the old one immediately.
  Future<String> rotateToken(String botId) async {
    try {
      final token = await _client.rpc('bot_rotate_token', params: {'p_bot_id': botId});
      return '$token';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> delete(String botId) async {
    try {
      await _client.rpc('bot_delete', params: {'p_bot_id': botId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<BotCommand>> commands(String botId) async {
    try {
      final rows = await _client.rpc('bot_commands_list', params: {'p_bot_id': botId});
      return asMapList(rows).map(BotCommand.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Replaces the command set. [commands] is `[{command, description, builtin?}]`
  /// — a `builtin` runs inside the platform, so automation needs no server.
  Future<void> setCommands(String botId, List<Map<String, Object?>> commands) async {
    try {
      await _client.rpc('bot_set_commands', params: <String, Object?>{
        'p_bot_id': botId,
        'p_commands': commands,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Adds a bot to a chat or a community. The permission mask is clamped to
  /// what the installer holds, so nobody can hand out power they do not have.
  Future<void> install(String botId, String chatId, {int? permissions}) async {
    try {
      await _client.rpc('bot_install', params: <String, Object?>{
        'p_bot_id': botId,
        'p_chat_id': chatId,
        'p_permissions': permissions,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> uninstall(String botId, String chatId) async {
    try {
      await _client.rpc('bot_uninstall', params: {'p_bot_id': botId, 'p_chat_id': chatId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<BotCommand>> chatCommands(String chatId) async {
    try {
      final rows = await _client.rpc('bot_chat_commands', params: {'p_chat_id': chatId});
      return asMapList(rows).map(BotCommand.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `@bot query` from a composer: the bot answers inline, nothing is sent yet.
  Future<({String queryId, List<InlineResult> results})> inlineQuery(
    String botUsername,
    String query, {
    String? chatId,
  }) async {
    try {
      final data = asMap(await _client.rpc('bot_inline_query', params: <String, Object?>{
        'p_bot': botUsername,
        'p_query': query,
        'p_chat_id': chatId,
      }));
      return (
        queryId: '${data['query_id']}',
        results: asMapList(data['results']).map(InlineResult.fromMap).toList(growable: false),
      );
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> sendInlineResult({
    required String queryId,
    required String resultId,
    required String chatId,
    String? body,
    Map<String, dynamic>? media,
  }) async {
    try {
      await _client.rpc('bot_inline_send', params: <String, Object?>{
        'p_query_id': queryId,
        'p_result_id': resultId,
        'p_chat_id': chatId,
        'p_body': body,
        'p_media': media,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Points a bot at an HTTPS endpoint. The payload is signed with the install's
  /// secret, so the receiver can trust it without a round trip back to us.
  Future<void> setWebhook(String botId, String? url) async {
    try {
      await _client.rpc('bot_webhook_set', params: <String, Object?>{
        'p_bot_id': botId,
        'p_url': url,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Automated moderation: keyword, link, invite-link, mention-limit, caps,
  /// flood or new-account rules, with a delete/warn/mute/kick/ban action.
  Future<void> saveRule(
    String botId, {
    String? ruleId,
    String kind = 'keyword',
    Map<String, dynamic> config = const <String, dynamic>{},
    String action = 'delete',
    String? chatId,
    String? communityId,
    int? durationMinutes,
    bool enabled = true,
  }) async {
    try {
      await _client.rpc('bot_rules_save', params: <String, Object?>{
        'p_bot_id': botId,
        'p_rule_id': ruleId,
        'p_kind': kind,
        'p_config': config,
        'p_action': action,
        'p_chat_id': chatId,
        'p_community_id': communityId,
        'p_duration_minutes': durationMinutes,
        'p_is_enabled': enabled,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<Map<String, dynamic>>> rules(String botId) async {
    try {
      final rows = await _client.rpc('bot_rules_list', params: {'p_bot_id': botId});
      return asMapList(rows);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// A scheduled broadcast: one message, sent once or on a repeat, to every
  /// chat the bot is installed in (or one of them).
  Future<String> scheduleBroadcast(
    String botId, {
    required String body,
    String? chatId,
    String? communityId,
    DateTime? sendAt,
    int? repeatSeconds,
    Map<String, dynamic>? media,
  }) async {
    try {
      final id = await _client.rpc('bot_broadcast_schedule', params: <String, Object?>{
        'p_bot_id': botId,
        'p_body': body,
        'p_chat_id': chatId,
        'p_community_id': communityId,
        'p_send_at': sendAt?.toUtc().toIso8601String(),
        'p_repeat_seconds': repeatSeconds,
        'p_media': media,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<Map<String, dynamic>>> broadcasts(String botId) async {
    try {
      final rows = await _client.rpc('bot_broadcast_list', params: {'p_bot_id': botId});
      return asMapList(rows);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> cancelBroadcast(String broadcastId) async {
    try {
      await _client.rpc('bot_broadcast_cancel', params: {'p_broadcast_id': broadcastId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Calls the bot's own API with its token — the same shape Telegram uses, so
  /// a bot written for this platform is portable and vice versa.
  Future<Map<String, dynamic>> api(String token, String method, [Map<String, Object?> payload = const {}]) async {
    try {
      final response = await _client.functions.invoke('bot-api', body: <String, Object?>{
        'token': token,
        'method': method,
        'payload': payload,
      });
      return asMap(response.data);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}
