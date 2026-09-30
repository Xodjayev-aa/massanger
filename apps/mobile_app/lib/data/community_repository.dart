import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'social_models.dart';

/// Permissions as the database stores them: one bigint bit per capability.
/// The mirrors here exist so the UI can hide what the server would refuse —
/// never as the check itself, which is always `channel_can`/`community_can`.
class CommunityPermissions {
  const CommunityPermissions._();

  static const int administrator = 1 << 0;
  static const int manageCommunity = 1 << 1;
  static const int manageRoles = 1 << 2;
  static const int manageChannels = 1 << 3;
  static const int kickMembers = 1 << 4;
  static const int banMembers = 1 << 5;
  static const int createInvites = 1 << 6;
  static const int viewAudit = 1 << 7;
  static const int viewChannel = 1 << 8;
  static const int sendMessages = 1 << 9;
  static const int manageMessages = 1 << 10;
  static const int attachFiles = 1 << 11;
  static const int addReactions = 1 << 12;
  static const int mentionEveryone = 1 << 13;
  static const int moderateMembers = 1 << 14;
  static const int createThreads = 1 << 15;
  static const int connectVoice = 1 << 16;

  static bool has(int mask, int permission) => (mask & permission) != 0;

  /// The bits a role editor offers, in display order.
  static const Map<int, String> labels = <int, String>{
    viewChannel: 'View channels',
    sendMessages: 'Send messages',
    createThreads: 'Create threads',
    attachFiles: 'Attach files',
    addReactions: 'Add reactions',
    manageMessages: 'Delete others’ messages',
    moderateMembers: 'Mute and warn members',
    kickMembers: 'Kick members',
    banMembers: 'Ban members',
    createInvites: 'Create invites',
    manageChannels: 'Manage channels',
    manageRoles: 'Manage roles',
    manageCommunity: 'Manage the community',
    mentionEveryone: 'Mention @everyone',
    connectVoice: 'Join voice',
  };
}

/// A text, voice, forum or announcement channel inside a community.
class CommunityChannel {
  const CommunityChannel({
    required this.id,
    required this.communityId,
    required this.name,
    required this.kind,
    required this.position,
    this.chatId,
    this.topic,
    this.categoryId,
    this.isPrivate = false,
    this.slowmodeSeconds = 0,
    this.userLimit = 0,
    this.unreadCount = 0,
    this.lastMessageAt,
    this.voiceCount = 0,
  });

  final String id;
  final String communityId;
  final String name;

  /// `text` | `voice` | `forum` | `announcement` | `stage`
  final String kind;
  final int position;
  final String? chatId;
  final String? topic;
  final String? categoryId;
  final bool isPrivate;
  final int slowmodeSeconds;
  final int userLimit;
  final int unreadCount;
  final DateTime? lastMessageAt;
  final int voiceCount;

  bool get isVoice => kind == 'voice' || kind == 'stage';

  /// The house-style prefix Discord made familiar.
  String get display => switch (kind) {
        'voice' => name,
        'stage' => name,
        'announcement' => name,
        'forum' => name,
        _ => name,
      };

  String get icon => switch (kind) {
        'voice' || 'stage' => '🔊',
        'announcement' => '📣',
        'forum' => '🧵',
        _ => '#',
      };

  factory CommunityChannel.fromMap(Map<String, dynamic> map) => CommunityChannel(
        id: '${map['id']}',
        communityId: '${map['community_id']}',
        name: '${map['name'] ?? ''}',
        kind: '${map['kind'] ?? 'text'}',
        position: (map['position'] as num?)?.toInt() ?? 0,
        chatId: map['chat_id'] as String?,
        topic: map['topic'] as String?,
        categoryId: map['category_id'] as String?,
        isPrivate: map['is_private'] == true,
        slowmodeSeconds: (map['slowmode_seconds'] as num?)?.toInt() ?? 0,
        userLimit: (map['user_limit'] as num?)?.toInt() ?? 0,
        unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
        lastMessageAt: map['last_message_at'] == null
            ? null
            : DateTime.tryParse('${map['last_message_at']}')?.toUtc(),
        voiceCount: (map['voice_count'] as num?)?.toInt() ?? 0,
      );
}

/// A category: the collapsible groups the channel list renders under.
class ChannelCategory {
  const ChannelCategory({required this.id, required this.name, required this.position});

  final String id;
  final String name;
  final int position;

  factory ChannelCategory.fromMap(Map<String, dynamic> map) => ChannelCategory(
        id: '${map['id']}',
        name: '${map['name'] ?? ''}',
        position: (map['position'] as num?)?.toInt() ?? 0,
      );
}

/// A role, with the bitmask the server enforces.
class CommunityRole {
  const CommunityRole({
    required this.id,
    required this.name,
    required this.color,
    required this.permissions,
    required this.position,
    this.hoisted = false,
    this.mentionable = true,
    this.isDefault = false,
    this.memberCount = 0,
  });

  final String id;
  final String name;
  final String color;
  final int permissions;
  final int position;
  final bool hoisted;
  final bool mentionable;
  final bool isDefault;
  final int memberCount;

  factory CommunityRole.fromMap(Map<String, dynamic> map) => CommunityRole(
        id: '${map['id']}',
        name: '${map['name'] ?? ''}',
        color: '${map['color'] ?? '#99aab5'}',
        permissions: (map['permissions'] as num?)?.toInt() ?? 0,
        position: (map['position'] as num?)?.toInt() ?? 0,
        hoisted: map['is_hoisted'] == true,
        mentionable: map['is_mentionable'] != false,
        isDefault: map['is_default'] == true,
        memberCount: (map['member_count'] as num?)?.toInt() ?? 0,
      );
}

/// A community member as the member list shows them.
class CommunityMember {
  const CommunityMember({
    required this.userId,
    required this.username,
    this.displayName,
    this.nickname,
    this.avatarPath,
    this.roleIds = const <String>[],
    this.joinedAt,
    this.isOnline = false,
  });

  final String userId;
  final String username;
  final String? displayName;
  final String? nickname;
  final String? avatarPath;
  final List<String> roleIds;
  final DateTime? joinedAt;
  final bool isOnline;

  String get name => nickname ?? displayName ?? username;

  factory CommunityMember.fromMap(Map<String, dynamic> map) => CommunityMember(
        userId: '${map['user_id']}',
        username: '${map['username'] ?? ''}',
        displayName: map['display_name'] as String?,
        nickname: map['nickname'] as String?,
        avatarPath: map['avatar_path'] as String?,
        roleIds: (map['role_ids'] is List)
            ? (map['role_ids'] as List).map((id) => '$id').toList(growable: false)
            : const <String>[],
        joinedAt: map['joined_at'] == null ? null : DateTime.tryParse('${map['joined_at']}')?.toUtc(),
        isOnline: map['is_online'] == true,
      );
}

/// Who is in a voice channel right now, and what they are doing.
class VoiceState {
  const VoiceState({
    required this.userId,
    required this.channelId,
    this.username,
    this.displayName,
    this.avatarPath,
    this.isMuted = false,
    this.isDeafened = false,
    this.isVideo = false,
    this.isStreaming = false,
    this.joinedAt,
  });

  final String userId;
  final String channelId;
  final String? username;
  final String? displayName;
  final String? avatarPath;
  final bool isMuted;
  final bool isDeafened;
  final bool isVideo;
  final bool isStreaming;
  final DateTime? joinedAt;

  String get name => displayName ?? username ?? 'Someone';

  factory VoiceState.fromMap(Map<String, dynamic> map) => VoiceState(
        userId: '${map['user_id']}',
        channelId: '${map['channel_id']}',
        username: map['username'] as String?,
        displayName: map['display_name'] as String?,
        avatarPath: map['avatar_path'] as String?,
        isMuted: map['is_muted'] == true,
        isDeafened: map['is_deafened'] == true,
        isVideo: map['is_video'] == true,
        isStreaming: map['is_streaming'] == true,
        joinedAt: map['joined_at'] == null ? null : DateTime.tryParse('${map['joined_at']}')?.toUtc(),
      );
}

/// Everything the community screen needs, in one round trip.
class CommunityOverview {
  const CommunityOverview({
    required this.community,
    this.channels = const <CommunityChannel>[],
    this.categories = const <ChannelCategory>[],
    this.roles = const <CommunityRole>[],
    this.members = const <CommunityMember>[],
    this.voice = const <VoiceState>[],
    this.myPermissions = 0,
    this.myRoleIds = const <String>[],
  });

  final CommunitySummary community;
  final List<CommunityChannel> channels;
  final List<ChannelCategory> categories;
  final List<CommunityRole> roles;
  final List<CommunityMember> members;
  final List<VoiceState> voice;
  final int myPermissions;
  final List<String> myRoleIds;

  bool get canManageChannels =>
      CommunityPermissions.has(myPermissions, CommunityPermissions.manageChannels) ||
      CommunityPermissions.has(myPermissions, CommunityPermissions.administrator);

  bool get canManageRoles =>
      CommunityPermissions.has(myPermissions, CommunityPermissions.manageRoles) ||
      CommunityPermissions.has(myPermissions, CommunityPermissions.administrator);

  bool get canModerate =>
      CommunityPermissions.has(myPermissions, CommunityPermissions.kickMembers) ||
      CommunityPermissions.has(myPermissions, CommunityPermissions.banMembers) ||
      CommunityPermissions.has(myPermissions, CommunityPermissions.moderateMembers) ||
      CommunityPermissions.has(myPermissions, CommunityPermissions.administrator);

  factory CommunityOverview.fromMap(Map<String, dynamic> map) {
    // `community_overview` nests the community under its own key; a projection
    // that flattens it (or a client one migration ahead) still parses.
    final community = asMap(map['community']);
    return CommunityOverview(
      community: CommunitySummary.fromMap(community.isEmpty ? map : community),
      channels: asMapList(map['channels']).map(CommunityChannel.fromMap).toList(growable: false),
      categories: asMapList(map['categories']).map(ChannelCategory.fromMap).toList(growable: false),
      roles: asMapList(map['roles']).map(CommunityRole.fromMap).toList(growable: false),
      members: asMapList(map['members']).map(CommunityMember.fromMap).toList(growable: false),
      voice: asMapList(map['voice']).map(VoiceState.fromMap).toList(growable: false),
      myPermissions: (map['my_permissions'] as num?)?.toInt() ?? 0,
      myRoleIds: (map['my_role_ids'] is List)
          ? (map['my_role_ids'] as List).map((id) => '$id').toList(growable: false)
          : const <String>[],
    );
  }
}

/// Communities (Discord-style servers) and broadcast channels (Telegram-style).
///
/// Both are chats underneath — a community channel is a `chats` row with a
/// channel wrapper, a broadcast channel is a `chats` row of kind `channel` — so
/// message history, reactions, pins and realtime all come for free and only the
/// *permissions* are new.
class CommunityRepository {
  CommunityRepository(this._client);

  final SupabaseClient _client;

  // ---------------------------------------------------------------------------
  // communities
  // ---------------------------------------------------------------------------

  Future<List<CommunitySummary>> mine() async {
    try {
      final data = await _client.rpc('community_my');
      return asMapList(data).map(CommunitySummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<CommunitySummary>> directory({String? query, int limit = 30}) async {
    try {
      final rows = await _client.rpc('community_directory', params: <String, Object?>{
        'p_query': query,
        'p_limit': limit,
      });
      return asMapList(rows).map(CommunitySummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> create({
    required String name,
    required String slug,
    String? description,
    bool isPublic = true,
    String? iconKey,
  }) async {
    try {
      final id = await _client.rpc('community_create', params: <String, Object?>{
        'p_name': name,
        'p_slug': slug,
        'p_description': description,
        'p_is_public': isPublic,
        'p_icon_key': iconKey,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> update(
    String communityId, {
    String? name,
    String? description,
    bool? isPublic,
    String? iconKey,
  }) async {
    try {
      await _client.rpc('community_update', params: <String, Object?>{
        'p_community_id': communityId,
        'p_name': name,
        'p_description': description,
        'p_is_public': isPublic,
        'p_icon_key': iconKey,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Join by id, slug or invite code — whichever the caller has.
  Future<String> join({String? communityId, String? slug, String? invite}) async {
    try {
      final id = await _client.rpc('community_join', params: <String, Object?>{
        'p_community_id': communityId,
        'p_slug': slug,
        'p_invite': invite,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> leave(String communityId) async {
    try {
      await _client.rpc('community_leave', params: {'p_community_id': communityId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<CommunityOverview> overview(String communityId) async {
    try {
      final data = await _client.rpc('community_overview', params: {'p_community_id': communityId});
      return CommunityOverview.fromMap(asMap(data));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<int> permissions(String communityId) async {
    try {
      final value = await _client.rpc('community_my_permissions', params: {'p_community_id': communityId});
      return (value as num?)?.toInt() ?? 0;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // channels inside a community
  // ---------------------------------------------------------------------------

  Future<String> createChannel(
    String communityId, {
    required String name,
    String kind = 'text',
    String? categoryId,
    String? topic,
    bool isPrivate = false,
    int position = 0,
  }) async {
    try {
      final id = await _client.rpc('community_channel_create', params: <String, Object?>{
        'p_community_id': communityId,
        'p_name': name,
        'p_kind': kind,
        'p_category_id': categoryId,
        'p_topic': topic,
        'p_is_private': isPrivate,
        'p_position': position,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> updateChannel(
    String channelId, {
    String? name,
    String? topic,
    int? position,
    bool? isPrivate,
    int? slowmodeSeconds,
    String? categoryId,
    int? userLimit,
  }) async {
    try {
      await _client.rpc('community_channel_update', params: <String, Object?>{
        'p_channel_id': channelId,
        'p_name': name,
        'p_topic': topic,
        'p_position': position,
        'p_is_private': isPrivate,
        'p_slowmode_seconds': slowmodeSeconds,
        'p_category_id': categoryId,
        'p_user_limit': userLimit,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteChannel(String channelId) async {
    try {
      await _client.rpc('community_channel_delete', params: {'p_channel_id': channelId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Grant or deny bits to a role or one member on one channel.
  Future<void> setOverwrite(
    String channelId, {
    required String targetType,
    required String targetId,
    int allow = 0,
    int deny = 0,
  }) async {
    try {
      await _client.rpc('community_overwrite_set', params: <String, Object?>{
        'p_channel_id': channelId,
        'p_target_type': targetType,
        'p_target_id': targetId,
        'p_allow': allow,
        'p_deny': deny,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // roles and moderation
  // ---------------------------------------------------------------------------

  Future<String> createRole(
    String communityId, {
    required String name,
    String color = '#99aab5',
    int permissions = 0,
    bool hoisted = false,
    bool mentionable = true,
  }) async {
    try {
      final id = await _client.rpc('community_role_create', params: <String, Object?>{
        'p_community_id': communityId,
        'p_name': name,
        'p_color': color,
        'p_permissions': permissions,
        'p_hoisted': hoisted,
        'p_mentionable': mentionable,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> updateRole(
    String roleId, {
    String? name,
    String? color,
    int? permissions,
    bool? hoisted,
    bool? mentionable,
    int? position,
  }) async {
    try {
      await _client.rpc('community_role_update', params: <String, Object?>{
        'p_role_id': roleId,
        'p_name': name,
        'p_color': color,
        'p_permissions': permissions,
        'p_hoisted': hoisted,
        'p_mentionable': mentionable,
        'p_position': position,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteRole(String roleId) async {
    try {
      await _client.rpc('community_role_delete', params: {'p_role_id': roleId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> setMemberRoles(String communityId, String userId, List<String> roleIds) async {
    try {
      await _client.rpc('community_member_set_roles', params: <String, Object?>{
        'p_community_id': communityId,
        'p_user_id': userId,
        'p_role_ids': roleIds,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `kick` | `ban` | `unban` | `mute` | `unmute` | `nickname`
  Future<void> moderate(
    String communityId,
    String userId, {
    required String action,
    String? reason,
    int? minutes,
    String? nickname,
  }) async {
    try {
      await _client.rpc('community_member_moderate', params: <String, Object?>{
        'p_community_id': communityId,
        'p_user_id': userId,
        'p_action': action,
        'p_reason': reason,
        'p_minutes': minutes,
        'p_nickname': nickname,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> createInvite(
    String communityId, {
    int maxUses = 0,
    int expiresHours = 168,
    String? channelId,
  }) async {
    try {
      final code = await _client.rpc('community_invite_create', params: <String, Object?>{
        'p_community_id': communityId,
        'p_max_uses': maxUses,
        'p_expires_hours': expiresHours,
        'p_channel_id': channelId,
      });
      return '$code';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // voice presence
  // ---------------------------------------------------------------------------

  Future<void> voiceJoin(String channelId, String sessionId) async {
    try {
      await _client.rpc('voice_join', params: {'p_channel_id': channelId, 'p_session_id': sessionId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> voiceLeave(String channelId) async {
    try {
      await _client.rpc('voice_leave', params: {'p_channel_id': channelId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> voiceSetState(
    String channelId, {
    bool? muted,
    bool? deafened,
    bool? video,
    bool? streaming,
  }) async {
    try {
      await _client.rpc('voice_set_state', params: <String, Object?>{
        'p_channel_id': channelId,
        'p_is_muted': muted,
        'p_is_deafened': deafened,
        'p_is_video': video,
        'p_is_streaming': streaming,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // broadcast channels (Telegram mechanics)
  // ---------------------------------------------------------------------------

  Future<List<ChannelSummary>> channels() async {
    try {
      final rows = await _client.rpc('channel_mine');
      return asMapList(rows).map(ChannelSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<ChannelSummary>> channelDirectory({String? query, int limit = 30}) async {
    try {
      final rows = await _client.rpc('channel_directory', params: <String, Object?>{
        'p_query': query,
        'p_limit': limit,
      });
      return asMapList(rows).map(ChannelSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> createBroadcastChannel({
    required String title,
    required String handle,
    String? description,
    bool isPublic = true,
    String postPolicy = 'admins',
    String? avatarKey,
  }) async {
    try {
      final chatId = await _client.rpc('channel_create', params: <String, Object?>{
        'p_title': title,
        'p_handle': handle,
        'p_description': description,
        'p_is_public': isPublic,
        'p_post_policy': postPolicy,
        'p_avatar_key': avatarKey,
      });
      return '$chatId';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> joinChannel({String? chatId, String? handle}) async {
    try {
      final id = await _client.rpc('channel_join', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_handle': handle,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> leaveChannel(String chatId) async {
    try {
      await _client.rpc('channel_leave', params: {'p_chat_id': chatId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Make someone an admin (or an ordinary subscriber) of a channel.
  Future<void> setChannelRole(String chatId, String userId, String role) async {
    try {
      await _client.rpc('channel_set_role', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_user_id': userId,
        'p_role': role,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}
