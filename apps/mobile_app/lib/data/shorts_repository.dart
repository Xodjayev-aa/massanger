import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import '../core/video_limits.dart';
import 'video_repository.dart';

/// One row of the Shorts feed or Long video, plus the projection the overlay needs.
class ShortVideo {
  const ShortVideo({
    required this.id,
    required this.authorId,
    required this.key,
    required this.duration,
    required this.sizeBytes,
    required this.likeCount,
    required this.createdAt,
    this.caption,
    this.title,
    this.description,
    this.feedType = 'short',
    this.viewCount = 0,
    this.likedByMe = false,
    this.authorName,
    this.authorUsername,
    this.authorAvatarPath,
    this.authorRoleBadge,
    this.authorRoleColor,
    this.authorDiscriminator,
  });

  final String id;
  final String authorId;

  /// B2 object key, `shorts/<authorId>/app/…`.
  final String key;
  final Duration duration;
  final int sizeBytes;
  final int likeCount;
  final DateTime createdAt;
  final String? caption;
  final String? title;
  final String? description;
  final String feedType;
  final int viewCount;

  /// Local overlay: the feed's like set for *this* user, merged in by [page].
  final bool likedByMe;
  final String? authorName;
  final String? authorUsername;
  final String? authorAvatarPath;
  final String? authorRoleBadge;
  final String? authorRoleColor;
  final int? authorDiscriminator;

  bool get isLong => feedType == 'long';

  factory ShortVideo.fromMap(Map<String, dynamic> map) => ShortVideo(
        id: '${map['id']}',
        authorId: '${map['author_id']}',
        key: '${map['object_key']}',
        duration: Duration(milliseconds: (map['duration_ms'] as num?)?.toInt() ?? 0),
        sizeBytes: (map['size_bytes'] as num?)?.toInt() ?? 0,
        likeCount: (map['like_count'] as num?)?.toInt() ?? 0,
        caption: map['caption'] as String?,
        title: map['title'] as String?,
        description: map['description'] as String?,
        feedType: map['feed_type'] as String? ?? 'short',
        viewCount: (map['view_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse('${map['created_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  ShortVideo copyWith({
    int? likeCount,
    int? viewCount,
    bool? likedByMe,
    String? authorName,
    String? authorUsername,
    String? authorAvatarPath,
    String? authorRoleBadge,
    String? authorRoleColor,
    int? authorDiscriminator,
  }) =>
      ShortVideo(
        id: id,
        authorId: authorId,
        key: key,
        duration: duration,
        sizeBytes: sizeBytes,
        likeCount: likeCount ?? this.likeCount,
        createdAt: createdAt,
        caption: caption,
        title: title,
        description: description,
        feedType: feedType,
        viewCount: viewCount ?? this.viewCount,
        likedByMe: likedByMe ?? this.likedByMe,
        authorName: authorName ?? this.authorName,
        authorUsername: authorUsername ?? this.authorUsername,
        authorAvatarPath: authorAvatarPath ?? this.authorAvatarPath,
        authorRoleBadge: authorRoleBadge ?? this.authorRoleBadge,
        authorRoleColor: authorRoleColor ?? this.authorRoleColor,
        authorDiscriminator: authorDiscriminator ?? this.authorDiscriminator,
      );
}

/// Data layer for the Shorts feed: keyset paging (ids are UUIDv7, so `id`
/// *is* the recency order), the like toggle, and the publish flow.
class ShortsRepository {
  ShortsRepository(this._client, this._videos);

  final SupabaseClient _client;
  final VideoRepository _videos;

  static const int pageSize = 10;

  static const String _rowColumns =
      'id, author_id, object_key, duration_ms, size_bytes, caption, like_count, created_at, feed_type, title, description, view_count';

  /// The next page, newest first. [beforeId] is the last id of the previous
  /// page; null starts the feed. [feedType] filters by 'short' vs 'long'.
  Future<List<ShortVideo>> page({String? beforeId, int limit = pageSize, String? feedType, bool followingOnly = false}) async {
    try {
      var filter = _client.from('shorts').select(_rowColumns);
      if (feedType != null) {
        filter = filter.eq('feed_type', feedType);
      }
      if (followingOnly && _uidOrNull != null) {
        final followingRes = await _client.from('follows').select('following_id').eq('follower_id', _uidOrNull!);
        final followingIds = (followingRes as List<dynamic>).map((e) => '${(e as Map)['following_id']}').toList();
        if (followingIds.isEmpty) return <ShortVideo>[];
        final inList = '(${followingIds.map((id) => '"$id"').join(',')})';
        filter = filter.filter('author_id', 'in', inList);
      }
      if (beforeId != null && beforeId.isNotEmpty) filter = filter.lt('id', beforeId);
      final rows = await filter.order('id', ascending: false).limit(limit);
      final shorts = (rows as List<dynamic>)
          .map((row) => ShortVideo.fromMap(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      if (shorts.isEmpty) return shorts;

      final uid = _uidOrNull;
      final ids = shorts.map((short) => short.id).toList(growable: false);
      final inList = '(${ids.map((id) => '"$id"').join(',')})';
      final authorIds = shorts.map((short) => short.authorId).toSet();

      final futures = <Future<void>>[
        _authorDirectory(authorIds, shorts),
        if (uid != null)
          _client
              .from('short_likes')
              .select('short_id')
              .eq('user_id', uid)
              .filter('short_id', 'in', inList)
              .then((rows) {
                final liked = (rows as List<dynamic>).map((row) => '${(row as Map)['short_id']}').toSet();
                for (var i = 0; i < shorts.length; i++) {
                  if (liked.contains(shorts[i].id)) shorts[i] = shorts[i].copyWith(likedByMe: true);
                }
              }),
      ];
      await Future.wait(futures);
      return shorts;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Increments view count on a video.
  Future<void> recordView(String videoId) async {
    try {
      await _client.rpc('increment_video_views', params: <String, dynamic>{'p_video_id': videoId});
    } catch (_) {
      // Non-critical metric
    }
  }

  /// Optimistic callers flip their own state first and call this to persist.
  Future<void> like(String shortId) async {
    try {
      await _client.from('short_likes').insert(<String, Object?>{
        'short_id': shortId,
        'user_id': _uid,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> unlike(String shortId) async {
    try {
      await _client
          .from('short_likes')
          .delete()
          .eq('short_id', shortId)
          .eq('user_id', _uid);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The full publish flow: validate → presigned PUT → direct-to-B2 upload →
  /// server confirm (real size + duration) → insert the row with the
  /// *verified* numbers, never the declared ones.
  Future<ShortVideo> publish({
    required XFile file,
    String? caption,
    String? title,
    String? description,
    String feedType = 'short',
  }) async {
    final trimmedCaption = caption == null ? null : caption.trim();
    if (trimmedCaption != null && trimmedCaption.length > 500) {
      throw const AppException('bad_request', 'Short captions stay under 500 characters.');
    }
    final trimmedTitle = title?.trim();
    final trimmedDesc = description?.trim();

    final bytes = await file.readAsBytes();
    final duration = VideoLimits.preflight(file.name, bytes);
    final uid = _uid;

    final ticket = await _videos.requestUpload(
      scope: VideoScope.short,
      sizeBytes: bytes.length,
      duration: duration,
    );
    await VideoRepository.putBytes(url: ticket.url, bytes: bytes, contentType: ticket.contentType);
    final verified = await _videos.confirm(scope: VideoScope.short, key: ticket.key);

    final row = await _client
        .from('shorts')
        .insert(<String, Object?>{
          'author_id': uid,
          'object_key': verified.key,
          'mime': VideoLimits.mime,
          'duration_ms': verified.duration.inMilliseconds,
          'size_bytes': verified.sizeBytes,
          'feed_type': feedType,
          if (trimmedCaption != null && trimmedCaption.isNotEmpty) 'caption': trimmedCaption,
          if (trimmedTitle != null && trimmedTitle.isNotEmpty) 'title': trimmedTitle,
          if (trimmedDesc != null && trimmedDesc.isNotEmpty) 'description': trimmedDesc,
        })
        .select(_rowColumns)
        .single();
    final box = <ShortVideo>[ShortVideo.fromMap(Map<String, dynamic>.from(row))];

    // Attach the author projection now so the feed can prepend without a
    // visible placeholder flicker.
    await _authorDirectory(<String>{uid}, box);
    return box.first;
  }

  /// Watch a short: presigned GET, scope derived from the key.
  Future<String> watchUrl(ShortVideo short) => _videos.playbackUrl(key: short.key);

  String get _uid {
    final uid = _uidOrNull;
    if (uid == null) {
      throw const AppException('auth', 'Sign in first.');
    }
    return uid;
  }

  String? get _uidOrNull => _client.auth.currentUser?.id;

  /// Fills authorName/username/avatar from the public directory projection
  /// (profiles itself is not readable beyond your own row), in place.
  Future<void> _authorDirectory(Set<String> authorIds, List<ShortVideo> shorts) async {
    if (authorIds.isEmpty) return;
    final inList = '(${authorIds.map((id) => '"$id"').join(',')})';
    final rows = await _client
        .from('directory')
        .select('id, display_name, username, avatar_path, role_badge, role_color, discriminator')
        .filter('id', 'in', inList);
    // Guard before converting: `rows` is a dynamic list, and strict-casts
    // (analysis_options) rejects an implicit dynamic → Map conversion — the
    // same `is! Map` shape models.dart already uses for jsonb payloads.
    final byId = <String, Map<String, dynamic>>{};
    for (final raw in rows as List<dynamic>) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final id = row['id'];
      if (id is String) byId[id] = row;
    }
    for (var i = 0; i < shorts.length; i++) {
      final author = byId[shorts[i].authorId];
      if (author != null) {
        shorts[i] = shorts[i].copyWith(
          authorName: author['display_name'] as String?,
          authorUsername: author['username'] as String?,
          authorAvatarPath: author['avatar_path'] as String?,
          authorRoleBadge: author['role_badge'] as String?,
          authorRoleColor: author['role_color'] as String?,
          authorDiscriminator: author['discriminator'] as int?,
        );
      }
    }
  }
}
