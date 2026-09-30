import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'social_models.dart';

/// The long-form and vertical feeds, the watch page and the comment trees.
///
/// Everything here is an RPC, never a bare `select`: the SQL owns the
/// authorization (a private account's videos are filtered server-side), the
/// joins (author identity, my like/save/follow state in the same row) and the
/// pagination keys. The client's job is to render, which is why there is exactly
/// one place to fix a feed bug.
class FeedRepository {
  FeedRepository(this._client);

  final SupabaseClient _client;

  static const int videoPageSize = 24;
  static const int shortPageSize = 10;

  // ---------------------------------------------------------------------------
  // long-form
  // ---------------------------------------------------------------------------

  /// `for_you` | `following` | `trending` | `category`. [beforeAt]/[beforeId]
  /// are the keyset cursor: the last row of the previous page, verbatim.
  Future<List<VideoCard>> videos({
    String tab = 'for_you',
    String? category,
    String? query,
    DateTime? beforeAt,
    String? beforeId,
    int limit = videoPageSize,
  }) async {
    try {
      final rows = await _client.rpc('video_feed', params: <String, Object?>{
        'p_tab': tab,
        'p_category': category,
        'p_query': (query == null || query.trim().isEmpty) ? null : query.trim(),
        'p_before_at': beforeAt?.toUtc().toIso8601String(),
        'p_before_id': beforeId,
        'p_limit': limit,
      });
      return asMapList(rows).map(VideoCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// One creator's long-form catalogue, in the same row shape as [videos] so a
  /// channel grid and the home grid share a tile. [includePrivate] adds the
  /// caller's own drafts and unlisted uploads, which is what the Profile tab
  /// wants and a stranger's channel page must not get.
  Future<List<VideoCard>> authorVideos(
    String authorId, {
    DateTime? beforeAt,
    String? beforeId,
    int limit = videoPageSize,
    bool includePrivate = false,
  }) async {
    try {
      final rows = await _client.rpc('author_videos', params: <String, Object?>{
        'p_author_id': authorId,
        'p_before_at': beforeAt?.toUtc().toIso8601String(),
        'p_before_id': beforeId,
        'p_limit': limit,
        'p_include_private': includePrivate,
      });
      return asMapList(rows).map(VideoCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The watch page payload: video, author, chapters, sound and counts in one
  /// round trip.
  Future<Map<String, dynamic>> video(String videoId) async {
    try {
      final data = await _client.rpc('video_detail', params: {'p_video_id': videoId});
      return asMap(data);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Publishes a row for bytes that already landed in B2 and were confirmed by
  /// `video-ticket` — the key and the verified duration/size is all that travels.
  Future<String> publishVideo({
    required String objectKey,
    required String title,
    String? description,
    String? thumbnailKey,
    Duration? duration,
    int? sizeBytes,
    String visibility = 'public',
    String? category,
    List<String> tags = const <String>[],
    List<Map<String, Object?>> chapters = const <Map<String, Object?>>[],
    String? soundId,
    bool allowComments = true,
    bool isMature = false,
    String language = 'en',
  }) async {
    try {
      final id = await _client.rpc('publish_video', params: <String, Object?>{
        'p_object_key': objectKey,
        'p_title': title,
        'p_description': description,
        'p_duration_ms': duration?.inMilliseconds,
        'p_size_bytes': sizeBytes,
        'p_visibility': visibility,
        'p_category': category,
        'p_tags': tags,
        'p_chapters': chapters,
        'p_sound_id': soundId,
        'p_allow_comments': allowComments,
        'p_is_mature': isMature,
        'p_language': language,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> updateVideo(
    String videoId, {
    String? title,
    String? description,
    String? visibility,
    String? category,
    List<String>? tags,
    String? thumbnailKey,
    bool? allowComments,
  }) async {
    try {
      await _client.rpc('update_video', params: <String, Object?>{
        'p_video_id': videoId,
        'p_title': title,
        'p_description': description,
        'p_visibility': visibility,
        'p_category': category,
        'p_tags': tags,
        'p_thumbnail_key': thumbnailKey,
        'p_allow_comments': allowComments,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteVideo(String videoId) async {
    try {
      await _client.rpc('delete_video', params: {'p_video_id': videoId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `like` | `dislike` | `none`; returns the verdict the server settled on.
  Future<String> rateVideo(String videoId, String verdict) async {
    try {
      final result = await _client.rpc('rate_video', params: {
        'p_video_id': videoId,
        'p_verdict': verdict,
      });
      return '$result';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// One view per session, with the resume point. [sessionId] is minted by the
  /// player and stays the same for as long as the screen is open.
  Future<void> recordVideoView({
    required String videoId,
    required String sessionId,
    Duration watched = Duration.zero,
    Duration position = Duration.zero,
    bool completed = false,
    bool likedAfter = false,
  }) async {
    try {
      await _client.rpc('record_video_view', params: <String, Object?>{
        'p_video_id': videoId,
        'p_session_id': sessionId,
        'p_watched_ms': watched.inMilliseconds,
        'p_position_ms': position.inMilliseconds,
        'p_completed': completed,
        'p_liked_after': likedAfter,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> shareVideo(String videoId) async {
    try {
      await _client.rpc('video_share', params: {'p_video_id': videoId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<bool> toggleWatchLater(String videoId) async {
    try {
      final result = await _client.rpc('toggle_watch_later', params: {'p_video_id': videoId});
      return result == true;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<PlaylistSummary>> myPlaylists() async {
    try {
      final rows = await _client.rpc('my_playlists');
      return asMapList(rows).map(PlaylistSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<VideoCard>> watchHistory({int limit = 50}) async {
    try {
      final rows = await _client.rpc('watch_history', params: {'p_limit': limit});
      return asMapList(rows).map(VideoCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> clearWatchHistory() async {
    try {
      await _client.rpc('clear_watch_history');
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The category chips under the tabs: slug, label and how much is in there.
  Future<List<VideoCategory>> categories() async {
    try {
      final rows = await _client.rpc('video_categories_list');
      return asMapList(rows)
          .map((row) => VideoCategory(
                slug: '${row['slug']}',
                label: '${row['label']}',
                emoji: row['emoji'] as String?,
                videoCount: (row['video_count'] as num?)?.toInt() ?? 0,
              ))
          .toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Trending hashtags, for the search page and the composer's suggestions.
  Future<List<({String tag, int useCount, int recentCount})>> trendingHashtags({int limit = 24}) async {
    try {
      final rows = await _client.rpc('hashtag_trending', params: {'p_limit': limit});
      return asMapList(rows)
          .map((row) => (
                tag: '${row['tag']}',
                useCount: (row['use_count'] as num?)?.toInt() ?? 0,
                recentCount: (row['recent_count'] as num?)?.toInt() ?? 0,
              ))
          .toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The creator dashboard: totals over both engines plus the top rows.
  Future<Map<String, dynamic>> creatorStats() async {
    try {
      final data = await _client.rpc('creator_stats');
      return asMap(data);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // playlists
  // ---------------------------------------------------------------------------

  Future<String> createPlaylist(String title, {String? description, String visibility = 'private'}) async {
    try {
      final id = await _client.rpc('playlist_create', params: <String, Object?>{
        'p_title': title,
        'p_description': description,
        'p_visibility': visibility,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deletePlaylist(String playlistId) async {
    try {
      await _client.rpc('playlist_delete', params: {'p_playlist_id': playlistId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> addToPlaylist(String playlistId, String videoId) async {
    try {
      await _client.rpc('playlist_add', params: <String, Object?>{
        'p_playlist_id': playlistId,
        'p_video_id': videoId,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> removeFromPlaylist(String playlistId, String videoId) async {
    try {
      await _client.rpc('playlist_remove', params: <String, Object?>{
        'p_playlist_id': playlistId,
        'p_video_id': videoId,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<VideoCard>> playlistItems(String playlistId) async {
    try {
      final rows = await _client.rpc('playlist_items', params: {'p_playlist_id': playlistId});
      return asMapList(rows).map(VideoCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // comments
  // ---------------------------------------------------------------------------

  /// Top-level comments, or the replies of [parentId] when one is given.
  Future<List<CommentNode>> comments({
    String? videoId,
    String? shortId,
    String? parentId,
    String sort = 'top',
    DateTime? beforeAt,
    int limit = 20,
  }) async {
    try {
      final rows = await _client.rpc('comment_thread', params: <String, Object?>{
        'p_video_id': videoId,
        'p_short_id': shortId,
        'p_parent_id': parentId,
        'p_sort': sort,
        'p_before_at': beforeAt?.toUtc().toIso8601String(),
        'p_limit': limit,
      });
      return asMapList(rows).map(CommentNode.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> addComment({
    required String body,
    String? videoId,
    String? shortId,
    String? parentId,
  }) async {
    try {
      final id = await _client.rpc('comment_create', params: <String, Object?>{
        'p_body': body,
        'p_video_id': videoId,
        'p_short_id': shortId,
        'p_parent_id': parentId,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> updateComment(String commentId, String body) async {
    try {
      await _client.rpc('comment_update', params: {'p_comment_id': commentId, 'p_body': body});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteComment(String commentId) async {
    try {
      await _client.rpc('comment_delete', params: {'p_comment_id': commentId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> likeComment(String commentId, {bool like = true}) async {
    try {
      await _client.rpc('comment_like', params: {'p_comment_id': commentId, 'p_like': like});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Creator-only: pin a comment to the top of the thread.
  Future<void> pinComment(String commentId, {bool pinned = true}) async {
    try {
      await _client.rpc('comment_pin', params: {'p_comment_id': commentId, 'p_pinned': pinned});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The creator's heart, which is what the comment sorts by.
  Future<void> heartComment(String commentId, {bool hearted = true}) async {
    try {
      await _client.rpc('comment_heart', params: {'p_comment_id': commentId, 'p_hearted': hearted});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // shorts
  // ---------------------------------------------------------------------------

  /// `for_you` (longest watch ratio first) | `following` | `sound` | `saved` |
  /// `profile`. The same cursor rules as [videos].
  Future<List<ShortCard>> shorts({
    String tab = 'for_you',
    String? soundId,
    String? authorId,
    DateTime? beforeAt,
    String? beforeId,
    int limit = shortPageSize,
  }) async {
    try {
      final rows = await _client.rpc('shorts_feed', params: <String, Object?>{
        'p_tab': tab,
        'p_sound_id': soundId,
        'p_author_id': authorId,
        'p_before_at': beforeAt?.toUtc().toIso8601String(),
        'p_before_id': beforeId,
        'p_limit': limit,
      });
      return asMapList(rows).map(ShortCard.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// One short by id, for a share link, a notification tap or the single-reel
  /// page. Null means "the server did not let this caller see it", which the UI
  /// shows as a plain "not available" — never as an error.
  Future<ShortCard?> short(String shortId) async {
    try {
      final rows = await _client.rpc('short_detail', params: {'p_short_id': shortId});
      final list = asMapList(rows);
      return list.isEmpty ? null : ShortCard.fromMap(list.first);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<String> publishShort({
    required String objectKey,
    required Duration duration,
    required int sizeBytes,
    String? caption,
    String visibility = 'public',
    String? soundId,
    String kind = 'original',
    String? replyToShort,
    String? thumbnailKey,
    bool allowComments = true,
    String language = 'en',
  }) async {
    try {
      final id = await _client.rpc('publish_short', params: <String, Object?>{
        'p_object_key': objectKey,
        'p_duration_ms': duration.inMilliseconds,
        'p_size_bytes': sizeBytes,
        'p_caption': caption,
        'p_visibility': visibility,
        'p_sound_id': soundId,
        'p_kind': kind,
        'p_reply_to_short': replyToShort,
        'p_thumbnail_key': thumbnailKey,
        'p_allow_comments': allowComments,
        'p_language': language,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Returns true when the short is liked after the tap (TikTok's single button
  /// is a toggle, not a pair of like/dislike).
  Future<bool> rateShort(String shortId, {String kind = 'like'}) async {
    try {
      final result = await _client.rpc('rate_short', params: {'p_short_id': shortId, 'p_kind': kind});
      return result == true;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> recordShortView({
    required String shortId,
    required String sessionId,
    Duration watched = Duration.zero,
    bool completed = false,
    bool replayed = false,
    bool skippedEarly = false,
  }) async {
    try {
      await _client.rpc('record_short_view', params: <String, Object?>{
        'p_short_id': shortId,
        'p_session_id': sessionId,
        'p_watched_ms': watched.inMilliseconds,
        'p_completed': completed,
        'p_replayed': replayed,
        'p_skipped_early': skippedEarly,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The bookmark on a short. `rate_short(kind: 'save')` is the server's one
  /// write path for both counters, so the client never touches `short_saves`.
  Future<bool> toggleSaveShort(String shortId) => rateShort(shortId, kind: 'save');

  Future<void> shareShort(String shortId) async {
    try {
      await _client.rpc('share_short', params: {'p_short_id': shortId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteShort(String shortId) async {
    try {
      await _client.rpc('delete_short', params: {'p_short_id': shortId});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // sounds
  // ---------------------------------------------------------------------------

  Future<List<SoundSummary>> sounds({String? query, int limit = 30}) async {
    try {
      final rows = await _client.rpc('sounds_feed', params: <String, Object?>{
        'p_query': query,
        'p_limit': limit,
      });
      return asMapList(rows).map(SoundSummary.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Registers a sound. `origin: 'tts'` is the AI voice-over path: the script is
  /// stored and the device renders it, so no hosted synthesis is required.
  Future<String> createSound({
    required String title,
    required Duration duration,
    required int sizeBytes,
    required String objectKey,
    String mime = 'audio/mpeg',
    String origin = 'upload',
    String? artist,
    String license = 'user',
    String? voiceScript,
    String? voiceName,
    String? voiceLocale,
  }) async {
    try {
      final id = await _client.rpc('create_sound', params: <String, Object?>{
        'p_title': title,
        'p_object_key': objectKey,
        'p_duration_ms': duration.inMilliseconds,
        'p_size_bytes': sizeBytes,
        'p_mime': mime,
        'p_origin': origin,
        'p_artist': artist,
        'p_license': license,
        'p_voice_script': voiceScript,
        'p_voice_name': voiceName,
        'p_voice_locale': voiceLocale,
      });
      return '$id';
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  // ---------------------------------------------------------------------------
  // notifications
  // ---------------------------------------------------------------------------

  Future<List<NotificationItem>> notifications({DateTime? before, int limit = 40}) async {
    try {
      final rows = await _client.rpc('notifications_list', params: <String, Object?>{
        'p_before': before?.toUtc().toIso8601String(),
        'p_limit': limit,
      });
      return asMapList(rows).map(NotificationItem.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<int> unreadNotifications() async {
    try {
      final count = await _client.rpc('notifications_unread');
      return (count as num?)?.toInt() ?? 0;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> markNotificationsRead([List<String>? ids]) async {
    try {
      await _client.rpc('notifications_mark_read', params: <String, Object?>{'p_ids': ids});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}
