/// Models for the social, video, community and economy surfaces.
///
/// Every one of them is a *projection* of a server function: the SQL owns the
/// joins (author identity, my like, my save, follower counters), and Dart only
/// parses what it is given. That keeps pagination cheap and means a client one
/// migration behind never crashes on a missing key — each parser falls back.
///
/// Timestamps are always `DateTime` in UTC; the UI converts to local time.
library;

DateTime _time(Object? raw) =>
    DateTime.tryParse('$raw')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

int _int(Object? raw) => (raw as num?)?.toInt() ?? 0;

bool _bool(Object? raw) => raw == true;

Map<String, dynamic> asMap(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

List<Map<String, dynamic>> asMapList(Object? raw) =>
    raw is List ? raw.map(asMap).where((m) => m.isNotEmpty).toList(growable: false) : const <Map<String, dynamic>>[];

/// A user as another user sees them: the public card, never a private row.
class ProfileCard {
  const ProfileCard({
    required this.id,
    required this.username,
    this.discriminator = 0,
    this.displayName,
    this.avatarPath,
    this.bio,
    this.verified = false,
    this.isPrivate = false,
    this.accountKind = 'human',
    this.followerCount = 0,
    this.followingCount = 0,
    this.postCount = 0,
    this.isFollowing = false,
    this.followsMe = false,
    this.followState,
    this.tags = const <TagSummary>[],
  });

  final String id;
  final String username;
  final int discriminator;
  final String? displayName;
  final String? avatarPath;
  final String? bio;
  final bool verified;
  final bool isPrivate;
  final String accountKind;
  final int followerCount;
  final int followingCount;
  final int postCount;
  final bool isFollowing;
  final bool followsMe;

  /// pending | accepted | declined, when a follow edge exists.
  final String? followState;
  final List<TagSummary> tags;

  bool get isBot => accountKind == 'bot' || accountKind == 'system';

  /// What is rendered next to the name everywhere in the app.
  String get handle => '@$username#$discriminator';

  String get name => (displayName == null || displayName!.trim().isEmpty) ? username : displayName!;

  factory ProfileCard.fromMap(Map<String, dynamic> map) => ProfileCard(
        id: '${map['id'] ?? map['user_id'] ?? ''}',
        username: '${map['username'] ?? ''}',
        discriminator: _int(map['discriminator'] ?? map['author_discriminator']),
        displayName: (map['display_name'] ?? map['author_name']) as String?,
        avatarPath: (map['avatar_path'] ?? map['author_avatar']) as String?,
        bio: map['bio'] as String?,
        verified: _bool(map['verified'] ?? map['author_verified']),
        isPrivate: _bool(map['is_private']),
        accountKind: '${map['account_kind'] ?? 'human'}',
        followerCount: _int(map['follower_count'] ?? map['author_followers']),
        followingCount: _int(map['following_count']),
        postCount: _int(map['post_count']),
        isFollowing: _bool(map['is_following'] ?? map['followed_by_me']),
        followsMe: _bool(map['follows_me']),
        followState: map['follow_state'] as String?,
      );

  ProfileCard copyWith({bool? isFollowing, String? followState, List<TagSummary>? tags}) => ProfileCard(
        id: id,
        username: username,
        discriminator: discriminator,
        displayName: displayName,
        avatarPath: avatarPath,
        bio: bio,
        verified: verified,
        isPrivate: isPrivate,
        accountKind: accountKind,
        followerCount: followerCount,
        followingCount: followingCount,
        postCount: postCount,
        isFollowing: isFollowing ?? this.isFollowing,
        followsMe: followsMe,
        followState: followState ?? this.followState,
        tags: tags ?? this.tags,
      );
}

/// One custom profile tag: text, emoji and the style the owner bought.
class TagSummary {
  const TagSummary({
    required this.id,
    required this.text,
    this.emoji,
    this.style = const <String, dynamic>{},
    this.slot = 0,
    this.active = true,
  });

  final String id;
  final String text;
  final String? emoji;
  final Map<String, dynamic> style;
  final int slot;
  final bool active;

  factory TagSummary.fromMap(Map<String, dynamic> map) => TagSummary(
        id: '${map['id'] ?? ''}',
        text: '${map['text'] ?? ''}',
        emoji: map['emoji'] as String?,
        style: asMap(map['style']),
        slot: _int(map['slot']),
        active: map['active'] != false,
      );
}

/// A cosmetic the store sells (badge, avatar frame, nameplate, …).
class CosmeticSummary {
  const CosmeticSummary({
    required this.id,
    required this.slug,
    required this.kind,
    required this.name,
    this.description,
    this.rarity = 'common',
    this.priceStars = 0,
    this.style = const <String, dynamic>{},
    this.owned = false,
    this.equipped = false,
  });

  final String id;
  final String slug;
  final String kind;
  final String name;
  final String? description;
  final String rarity;
  final int priceStars;
  final Map<String, dynamic> style;
  final bool owned;
  final bool equipped;

  factory CosmeticSummary.fromMap(Map<String, dynamic> map) => CosmeticSummary(
        id: '${map['id'] ?? ''}',
        slug: '${map['slug'] ?? ''}',
        kind: '${map['kind'] ?? 'badge'}',
        name: '${map['name'] ?? ''}',
        description: map['description'] as String?,
        rarity: '${map['rarity'] ?? 'common'}',
        priceStars: _int(map['price_stars']),
        style: asMap(map['style']),
        owned: _bool(map['owned']),
        equipped: _bool(map['equipped']),
      );
}

/// `profile_identity(uuid)` — everything that decorates a name.
class ProfileIdentity {
  const ProfileIdentity({
    required this.userId,
    required this.username,
    this.discriminator = 0,
    this.tags = const <TagSummary>[],
    this.cosmetics = const <CosmeticSummary>[],
    this.verified = false,
    this.accountKind = 'human',
    this.badge,
  });

  final String userId;
  final String username;
  final int discriminator;
  final List<TagSummary> tags;
  final List<CosmeticSummary> cosmetics;
  final bool verified;
  final String accountKind;
  final String? badge;

  String get handle => '@$username#$discriminator';

  factory ProfileIdentity.fromMap(Map<String, dynamic> map) => ProfileIdentity(
        userId: '${map['user_id'] ?? ''}',
        username: '${map['username'] ?? ''}',
        discriminator: _int(map['discriminator']),
        tags: asMapList(map['tags']).map(TagSummary.fromMap).toList(growable: false),
        cosmetics: asMapList(map['cosmetics']).map(CosmeticSummary.fromMap).toList(growable: false),
        verified: _bool(map['verified']),
        accountKind: '${map['account_kind'] ?? 'human'}',
        badge: map['badge'] as String?,
      );
}

/// A row of the long-form feed / a search hit.
class VideoCard {
  const VideoCard({
    required this.id,
    required this.title,
    required this.authorId,
    required this.viewCount,
    required this.likeCount,
    required this.commentCount,
    required this.publishedAt,
    this.description,
    this.thumbnailKey,
    this.duration = Duration.zero,
    this.categorySlug,
    this.categoryLabel,
    this.authorName,
    this.authorUsername,
    this.authorDiscriminator = 0,
    this.authorAvatarPath,
    this.authorVerified = false,
    this.authorFollowers = 0,
    this.authorTags = const <TagSummary>[],
    this.followedByMe = false,
    this.myVerdict,
    this.progress = Duration.zero,
    this.visibility = 'public',
    this.isMature = false,
    this.soundId,
  });

  final String id;
  final String title;
  final String? description;
  final String authorId;
  final String? thumbnailKey;
  final Duration duration;
  final int viewCount;
  final int likeCount;
  final int commentCount;
  final DateTime publishedAt;
  final String? categorySlug;
  final String? categoryLabel;
  final String? authorName;
  final String? authorUsername;
  final int authorDiscriminator;
  final String? authorAvatarPath;
  final bool authorVerified;
  final int authorFollowers;
  final List<TagSummary> authorTags;
  final bool followedByMe;
  final String? myVerdict;
  final Duration progress;
  final String visibility;
  final bool isMature;
  final String? soundId;

  String get authorHandle =>
      authorUsername == null ? '' : '@$authorUsername#$authorDiscriminator';

  factory VideoCard.fromMap(Map<String, dynamic> map) => VideoCard(
        id: '${map['id']}',
        title: '${map['title'] ?? ''}',
        description: map['description'] as String?,
        authorId: '${map['author_id']}',
        thumbnailKey: map['thumbnail_key'] as String?,
        duration: Duration(milliseconds: _int(map['duration_ms'])),
        viewCount: _int(map['view_count']),
        likeCount: _int(map['like_count']),
        commentCount: _int(map['comment_count']),
        publishedAt: _time(map['published_at'] ?? map['created_at']),
        categorySlug: map['category_slug'] as String?,
        categoryLabel: map['category_label'] as String?,
        authorName: map['author_name'] as String?,
        authorUsername: map['author_username'] as String?,
        authorDiscriminator: _int(map['author_discriminator']),
        authorAvatarPath: map['author_avatar'] as String?,
        authorVerified: _bool(map['author_verified']),
        authorFollowers: _int(map['author_followers']),
        followedByMe: _bool(map['followed_by_me']),
        myVerdict: map['my_verdict'] as String?,
        progress: Duration(milliseconds: _int(map['progress_ms'])),
        visibility: '${map['visibility'] ?? 'public'}',
        isMature: _bool(map['is_mature']),
        soundId: map['sound_id'] as String?,
      );

  VideoCard copyWith({String? myVerdict, int? likeCount, bool? followedByMe, Duration? progress}) => VideoCard(
        id: id,
        title: title,
        description: description,
        authorId: authorId,
        thumbnailKey: thumbnailKey,
        duration: duration,
        viewCount: viewCount,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount,
        publishedAt: publishedAt,
        categorySlug: categorySlug,
        categoryLabel: categoryLabel,
        authorName: authorName,
        authorUsername: authorUsername,
        authorDiscriminator: authorDiscriminator,
        authorAvatarPath: authorAvatarPath,
        authorVerified: authorVerified,
        authorFollowers: authorFollowers,
        authorTags: authorTags,
        followedByMe: followedByMe ?? this.followedByMe,
        myVerdict: myVerdict ?? this.myVerdict,
        progress: progress ?? this.progress,
        visibility: visibility,
        isMature: isMature,
        soundId: soundId,
      );
}

/// A full-screen vertical short.
class ShortCard {
  const ShortCard({
    required this.id,
    required this.authorId,
    required this.key,
    required this.likeCount,
    required this.viewCount,
    required this.createdAt,
    this.caption,
    this.duration = Duration.zero,
    this.kind = 'original',
    this.soundId,
    this.soundTitle,
    this.soundArtist,
    this.soundOrigin,
    this.thumbnailKey,
    this.replyToShort,
    this.likedByMe = false,
    this.savedByMe = false,
    this.authorName,
    this.authorUsername,
    this.authorDiscriminator = 0,
    this.authorAvatarPath,
    this.authorVerified = false,
    this.followedByMe = false,
    this.authorTags = const <TagSummary>[],
    this.playbackUrl,
  });

  final String id;
  final String authorId;

  /// B2 object key: `shorts/<authorId>/app/…`.
  final String key;
  final String? thumbnailKey;
  final Duration duration;
  final String? caption;
  final String kind;
  final String visibilityDefault = 'public';
  final int likeCount;
  final int viewCount;
  final DateTime createdAt;
  final String? soundId;
  final String? soundTitle;
  final String? soundArtist;
  final String? soundOrigin;
  final String? replyToShort;
  final bool likedByMe;
  final bool savedByMe;
  final String? authorName;
  final String? authorUsername;
  final int authorDiscriminator;
  final String? authorAvatarPath;
  final bool authorVerified;
  final bool followedByMe;
  final List<TagSummary> authorTags;

  /// Filled in by the page once the signed URL arrives.
  final String? playbackUrl;

  String get authorHandle =>
      authorUsername == null ? '' : '@$authorUsername#$authorDiscriminator';

  factory ShortCard.fromMap(Map<String, dynamic> map) => ShortCard(
        id: '${map['id']}',
        authorId: '${map['author_id']}',
        key: '${map['object_key']}',
        thumbnailKey: map['thumbnail_key'] as String?,
        duration: Duration(milliseconds: _int(map['duration_ms'])),
        caption: map['caption'] as String?,
        kind: '${map['kind'] ?? 'original'}',
        likeCount: _int(map['like_count']),
        viewCount: _int(map['view_count']),
        createdAt: _time(map['created_at']),
        soundId: map['sound_id'] as String?,
        soundTitle: map['sound_title'] as String?,
        soundArtist: map['sound_artist'] as String?,
        soundOrigin: map['sound_origin'] as String?,
        replyToShort: map['reply_to_short'] as String?,
        likedByMe: _bool(map['liked_by_me']),
        savedByMe: _bool(map['saved_by_me']),
        authorName: map['author_name'] as String?,
        authorUsername: map['author_username'] as String?,
        authorDiscriminator: _int(map['author_discriminator']),
        authorAvatarPath: map['author_avatar'] as String?,
        authorVerified: _bool(map['author_verified']),
        followedByMe: _bool(map['followed_by_me']),
      );

  ShortCard copyWith({
    String? playbackUrl,
    int? likeCount,
    bool? likedByMe,
    bool? savedByMe,
    bool? followedByMe,
    List<TagSummary>? authorTags,
  }) =>
      ShortCard(
        id: id,
        authorId: authorId,
        key: key,
        thumbnailKey: thumbnailKey,
        duration: duration,
        caption: caption,
        kind: kind,
        likeCount: likeCount ?? this.likeCount,
        viewCount: viewCount,
        createdAt: createdAt,
        soundId: soundId,
        soundTitle: soundTitle,
        soundArtist: soundArtist,
        soundOrigin: soundOrigin,
        replyToShort: replyToShort,
        likedByMe: likedByMe ?? this.likedByMe,
        savedByMe: savedByMe ?? this.savedByMe,
        authorName: authorName,
        authorUsername: authorUsername,
        authorDiscriminator: authorDiscriminator,
        authorAvatarPath: authorAvatarPath,
        authorVerified: authorVerified,
        followedByMe: followedByMe ?? this.followedByMe,
        authorTags: authorTags ?? this.authorTags,
        playbackUrl: playbackUrl ?? this.playbackUrl,
      );
}

/// A comment with its reply count, heart and like state.
class CommentNode {
  const CommentNode({
    required this.id,
    required this.body,
    required this.likeCount,
    required this.createdAt,
    this.videoId,
    this.shortId,
    this.parentId,
    this.authorId,
    this.authorName,
    this.authorUsername,
    this.authorDiscriminator = 0,
    this.authorAvatarPath,
    this.authorVerified = false,
    this.authorTags = const <TagSummary>[],
    this.replyCount = 0,
    this.isPinned = false,
    this.isHearted = false,
    this.likedByMe = false,
    this.canReply = true,
    this.deleted = false,
  });

  final String id;
  final String? videoId;
  final String? shortId;
  final String? parentId;
  final String? authorId;
  final String body;
  final int likeCount;
  final DateTime createdAt;
  final String? authorName;
  final String? authorUsername;
  final int authorDiscriminator;
  final String? authorAvatarPath;
  final bool authorVerified;
  final List<TagSummary> authorTags;
  final int replyCount;
  final bool isPinned;
  final bool isHearted;
  final bool likedByMe;
  final bool canReply;
  final bool deleted;

  String get authorHandle =>
      authorUsername == null ? '' : '@$authorUsername#$authorDiscriminator';

  factory CommentNode.fromMap(Map<String, dynamic> map) => CommentNode(
        id: '${map['id']}',
        videoId: map['video_id'] as String?,
        shortId: map['short_id'] as String?,
        parentId: map['parent_id'] as String?,
        authorId: map['author_id'] as String?,
        body: '${map['body'] ?? ''}',
        likeCount: _int(map['like_count']),
        createdAt: _time(map['created_at']),
        authorName: map['author_name'] as String?,
        authorUsername: map['author_username'] as String?,
        authorDiscriminator: _int(map['author_discriminator']),
        authorAvatarPath: map['author_avatar'] as String?,
        authorVerified: _bool(map['author_verified']),
        replyCount: _int(map['reply_count']),
        isPinned: _bool(map['is_pinned']),
        isHearted: _bool(map['is_hearted']),
        likedByMe: _bool(map['liked_by_me']),
        canReply: map['can_reply'] != false,
      );

  CommentNode copyWith({int? likeCount, bool? likedByMe, int? replyCount}) => CommentNode(
        id: id,
        videoId: videoId,
        shortId: shortId,
        parentId: parentId,
        authorId: authorId,
        body: body,
        likeCount: likeCount ?? this.likeCount,
        createdAt: createdAt,
        authorName: authorName,
        authorUsername: authorUsername,
        authorDiscriminator: authorDiscriminator,
        authorAvatarPath: authorAvatarPath,
        authorVerified: authorVerified,
        authorTags: authorTags,
        replyCount: replyCount ?? this.replyCount,
        isPinned: isPinned,
        isHearted: isHearted,
        likedByMe: likedByMe ?? this.likedByMe,
        canReply: canReply,
        deleted: deleted,
      );
}

/// A reusable sound: an upload, an extracted track or our own AI voice-over.
class SoundSummary {
  const SoundSummary({
    required this.id,
    required this.title,
    required this.origin,
    required this.useCount,
    this.artist,
    this.duration = Duration.zero,
    this.objectKey,
    this.voiceScript,
    this.voiceName,
    this.voiceLocale,
    this.coverKey,
  });

  final String id;
  final String title;
  final String origin;
  final int useCount;
  final String? artist;
  final Duration duration;
  final String? objectKey;
  final String? coverKey;

  /// Present when `origin = 'tts'`: the text the device re-renders, so an
  /// AI voice-over costs a row rather than a hosted synthesis call.
  final String? voiceScript;
  final String? voiceName;
  final String? voiceLocale;

  bool get isVoiceOver => origin == 'tts';

  factory SoundSummary.fromMap(Map<String, dynamic> map) => SoundSummary(
        id: '${map['id']}',
        title: '${map['title'] ?? 'Original sound'}',
        origin: '${map['origin'] ?? 'upload'}',
        useCount: _int(map['use_count']),
        artist: map['artist'] as String?,
        duration: Duration(milliseconds: _int(map['duration_ms'])),
        objectKey: map['object_key'] as String?,
        coverKey: map['cover_key'] as String?,
        voiceScript: map['voice_script'] as String?,
        voiceName: map['voice_name'] as String?,
        voiceLocale: map['voice_locale'] as String?,
      );
}

/// One row of the notification inbox: actors, kinds and the payload the server
/// already resolved (no client-side join, no missing avatar).
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.readAt,
    this.actorId,
    this.actorName,
    this.actorUsername,
    this.actorDiscriminator = 0,
    this.actorAvatarPath,
    this.videoId,
    this.shortId,
    this.chatId,
    this.commentId,
    this.payload = const <String, dynamic>{},
  });

  final String id;
  final String kind;
  final DateTime createdAt;
  final DateTime? readAt;
  final String? actorId;
  final String? actorName;
  final String? actorUsername;
  final int actorDiscriminator;
  final String? actorAvatarPath;
  final String? videoId;
  final String? shortId;
  final String? chatId;
  final String? commentId;
  final Map<String, dynamic> payload;

  bool get unread => readAt == null;

  factory NotificationItem.fromMap(Map<String, dynamic> map) => NotificationItem(
        id: '${map['id']}',
        kind: '${map['kind'] ?? 'system'}',
        createdAt: _time(map['created_at']),
        readAt: map['read_at'] == null ? null : _time(map['read_at']),
        actorId: map['actor_id'] as String?,
        actorName: (map['actor_name'] ?? map['actor_display_name']) as String?,
        actorUsername: map['actor_username'] as String?,
        actorDiscriminator: _int(map['actor_discriminator']),
        actorAvatarPath: map['actor_avatar'] as String?,
        videoId: map['video_id'] as String?,
        shortId: map['short_id'] as String?,
        chatId: map['chat_id'] as String?,
        commentId: map['comment_id'] as String?,
        payload: asMap(map['payload']),
      );
}

/// A watch-later list, a channel playlist or a search result group.
class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.title,
    required this.itemCount,
    this.description,
    this.visibility = 'private',
    this.systemSlug,
    this.coverKey,
  });

  final String id;
  final String title;
  final String? description;
  final int itemCount;
  final String visibility;
  final String? systemSlug;
  final String? coverKey;

  factory PlaylistSummary.fromMap(Map<String, dynamic> map) => PlaylistSummary(
        id: '${map['id']}',
        title: '${map['title'] ?? ''}',
        description: map['description'] as String?,
        itemCount: _int(map['item_count']),
        visibility: '${map['visibility'] ?? 'private'}',
        systemSlug: map['system_slug'] as String?,
        coverKey: map['cover_key'] as String?,
      );
}
