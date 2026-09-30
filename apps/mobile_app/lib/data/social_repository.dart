import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'social_models.dart';

/// Everything that is about *people* rather than content: the follow graph,
/// blocks, identity (tags and badges), the directory and global search.
///
/// The follow graph is asymmetric by design. A private account turns a follow
/// into a *request* that the owner answers, and a block is one row that the
/// server checks everywhere — this class never decides visibility itself.
class SocialRepository {
  SocialRepository(this._client);

  final SupabaseClient _client;

  /// The signed-in user, or null. Screens use it to decide what to offer (pin,
  /// delete, follow) — never as an authorization check, which the server owns.
  String? get currentUserId => _client.auth.currentUser?.id;

  // ---------------------------------------------------------------------------
  // follow graph
  // ---------------------------------------------------------------------------

  /// Follows by id, or by `@name#1234` when [handle] is given. Returns the
  /// resulting state: `accepted` for a public account, `pending` for a private
  /// one (and `pending` again if a request is already waiting).
  Future<String> follow({String? userId, String? handle}) async {
    try {
      final state = await _client.rpc('follow_user', params: <String, Object?>{
        'p_user_id': userId,
        'p_handle': handle,
      });
      return '$state';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> unfollow(String userId) async {
    try {
      await _client.rpc('unfollow_user', params: {'p_user_id': userId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The owner's side of a private account: accept or decline a request.
  /// A decline is sticky — the same person cannot keep asking.
  Future<void> respondToRequest(String followerId, {required bool accept}) async {
    try {
      await _client.rpc('respond_follow_request', params: {
        'p_follower_id': followerId,
        'p_accept': accept,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String?> followState(String userId) async {
    try {
      final state = await _client.rpc('follow_state', params: {'p_user_id': userId});
      return state == null ? null : '$state';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `all` | `following` | `none` — how loudly a new video from them rings.
  Future<void> setFollowNotifications(String userId, String level) async {
    try {
      await _client.rpc('set_follow_notifications', params: {
        'p_user_id': userId,
        'p_level': level,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<ProfileCard>> followList(
    String userId, {
    String direction = 'followers',
    int limit = 100,
  }) async {
    try {
      final rows = await _client.rpc('follow_list', params: <String, Object?>{
        'p_user_id': userId,
        'p_direction': direction,
        'p_limit': limit,
      });
      return asMapList(rows).map(ProfileCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> block(String userId, {String? reason}) async {
    try {
      await _client.rpc('block_user', params: <String, Object?>{'p_user_id': userId, 'p_reason': reason});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> unblock(String userId) async {
    try {
      await _client.rpc('unblock_user', params: {'p_user_id': userId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<ProfileCard>> blockedUsers() async {
    try {
      final rows = await _client.rpc('blocked_users');
      return asMapList(rows).map(ProfileCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // identity
  // ---------------------------------------------------------------------------

  /// Full public card, with the tags and badges that decorate the name.
  Future<ProfileCard?> profile(String userId) async {
    try {
      final data = await _client.rpc('profile_identity', params: {'p_user_id': userId});
      if (data == null) return null;
      final map = asMap(data);
      if (map.isEmpty) return null;
      return ProfileCard(
        id: '${map['id']}',
        username: '${map['username']}',
        discriminator: (map['discriminator'] as num?)?.toInt() ?? 0,
        displayName: map['display_name'] as String?,
        avatarPath: map['avatar_path'] as String?,
        bio: map['bio'] as String?,
        verified: map['verified'] == true,
        isPrivate: map['is_private'] == true,
        followerCount: (map['follower_count'] as num?)?.toInt() ?? 0,
        followingCount: (map['following_count'] as num?)?.toInt() ?? 0,
        postCount: (map['post_count'] as num?)?.toInt() ?? 0,
        isFollowing: map['followed_by_me'] == true,
        tags: asMapList(map['tags']).map(TagSummary.fromMap).toList(growable: false),
      );
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Batch identity for a page of rows: one call fills the tags for every author
  /// on screen, which is what keeps a feed at one round trip per page.
  Future<Map<String, List<TagSummary>>> tagsFor(Iterable<String> userIds) async {
    final ids = userIds.where((id) => id.isNotEmpty).toSet().toList(growable: false);
    if (ids.isEmpty) return <String, List<TagSummary>>{};
    try {
      final rows = await _client.rpc('profile_tags_batch', params: {'p_user_ids': ids});
      final out = <String, List<TagSummary>>{};
      for (final row in asMapList(rows)) {
        final userId = '${row['user_id']}';
        out[userId] = asMapList(row['tags']).map(TagSummary.fromMap).toList(growable: false);
      }
      return out;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // discovery
  // ---------------------------------------------------------------------------

  Future<List<ProfileCard>> people({String? query, int limit = 40}) async {
    try {
      final rows = await _client.rpc('people_directory', params: <String, Object?>{
        'p_query': query,
        'p_limit': limit,
      });
      return asMapList(rows).map(ProfileCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// People worth following: the people you already follow follow them, then
  /// whoever is easiest to find.
  Future<List<ProfileCard>> suggestions({int limit = 20}) async {
    try {
      final rows = await _client.rpc('follow_suggestions', params: {'p_limit': limit});
      return asMapList(rows).map(ProfileCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// One box, every surface: users, long-form videos, shorts, channels,
  /// communities and sounds.
  Future<SearchResults> search(String query) async {
    try {
      final data = await _client.rpc('search_all', params: {'p_query': query});
      return SearchResults.fromMap(asMap(data));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}

/// The grouped answer of `search_all`.
class SearchResults {
  const SearchResults({
    this.people = const <ProfileCard>[],
    this.videos = const <VideoCard>[],
    this.shorts = const <ShortCard>[],
    this.channels = const <ChannelSummary>[],
    this.communities = const <CommunitySummary>[],
    this.sounds = const <SoundSummary>[],
  });

  final List<ProfileCard> people;
  final List<VideoCard> videos;
  final List<ShortCard> shorts;
  final List<ChannelSummary> channels;
  final List<CommunitySummary> communities;
  final List<SoundSummary> sounds;

  bool get isEmpty =>
      people.isEmpty && videos.isEmpty && shorts.isEmpty && channels.isEmpty && communities.isEmpty && sounds.isEmpty;

  factory SearchResults.fromMap(Map<String, dynamic> map) => SearchResults(
        people: asMapList(map['people']).map(ProfileCard.fromMap).toList(growable: false),
        videos: asMapList(map['videos']).map(VideoCard.fromMap).toList(growable: false),
        shorts: asMapList(map['shorts']).map(ShortCard.fromMap).toList(growable: false),
        channels: asMapList(map['channels']).map(ChannelSummary.fromMap).toList(growable: false),
        communities: asMapList(map['communities']).map(CommunitySummary.fromMap).toList(growable: false),
        sounds: asMapList(map['sounds']).map(SoundSummary.fromMap).toList(growable: false),
      );
}

/// A Telegram-style broadcast channel: one voice, many readers.
class ChannelSummary {
  const ChannelSummary({
    required this.chatId,
    required this.title,
    this.handle,
    this.description,
    this.avatarPath,
    this.subscriberCount = 0,
    this.postPolicy = 'admins',
    this.isPublic = true,
    this.myRole = 'none',
    this.joined = false,
    this.unreadCount = 0,
  });

  final String chatId;
  final String title;
  final String? handle;
  final String? description;
  final String? avatarPath;
  final int subscriberCount;

  /// `everyone` | `admins` | `owner`.
  final String postPolicy;
  final bool isPublic;
  final String myRole;
  final bool joined;
  final int unreadCount;

  String get at => handle == null ? '' : '@$handle';

  factory ChannelSummary.fromMap(Map<String, dynamic> map) => ChannelSummary(
        chatId: '${map['chat_id'] ?? map['id']}',
        title: '${map['title'] ?? ''}',
        handle: map['handle'] as String?,
        description: map['description'] as String?,
        avatarPath: map['avatar_path'] as String?,
        subscriberCount: (map['subscriber_count'] as num?)?.toInt() ?? 0,
        postPolicy: '${map['post_policy'] ?? 'admins'}',
        isPublic: map['is_public'] != false,
        myRole: '${map['my_role'] ?? 'none'}',
        joined: map['joined'] == true,
        unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
      );
}

/// A Discord-style server: roles, categories, text and voice channels.
class CommunitySummary {
  const CommunitySummary({
    required this.id,
    required this.name,
    required this.slug,
    this.description,
    this.iconKey,
    this.bannerKey,
    this.memberCount = 0,
    this.onlineCount = 0,
    this.isPublic = true,
    this.joined = false,
    this.myPermissions = 0,
    this.isOwner = false,
  });

  final String id;
  final String name;
  final String slug;
  final String? description;
  final String? iconKey;
  final String? bannerKey;
  final int memberCount;
  final int onlineCount;
  final bool isPublic;
  final bool joined;
  final int myPermissions;
  final bool isOwner;

  factory CommunitySummary.fromMap(Map<String, dynamic> map) => CommunitySummary(
        id: '${map['id']}',
        name: '${map['name'] ?? ''}',
        slug: '${map['slug'] ?? ''}',
        description: map['description'] as String?,
        iconKey: map['icon_key'] as String?,
        bannerKey: map['banner_key'] as String?,
        memberCount: (map['member_count'] as num?)?.toInt() ?? 0,
        onlineCount: (map['online_count'] as num?)?.toInt() ?? 0,
        isPublic: map['is_public'] != false,
        joined: map['joined'] == true,
        myPermissions: (map['my_permissions'] as num?)?.toInt() ?? 0,
        isOwner: map['is_owner'] == true,
      );
}
