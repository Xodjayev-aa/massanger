import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/feed_repository.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';

/// The comment tree, rendered the way a modern feed does it: newest or top
/// first, one level of replies expanded in place, the creator's heart and pin
/// visible, and a composer that knows which surface it is posting on.
///
/// It is one widget because a short's comments and a video's comments are the
/// same object in the database (`comments` holds either a `video_id` or a
/// `short_id`), and keeping two implementations is how they drift apart.
class CommentsPanel extends StatefulWidget {
  const CommentsPanel({
    super.key,
    this.videoId,
    this.shortId,
    this.totalCount = 0,
    this.creatorId,
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
    this.scrollController,
  });

  final String? videoId;
  final String? shortId;
  final int totalCount;

  /// Whoever published the video/short: only they see pin and heart.
  final String? creatorId;
  final EdgeInsets padding;
  final bool shrinkWrap;
  final ScrollController? scrollController;

  @override
  State<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends State<CommentsPanel> {
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  final List<CommentNode> _roots = <CommentNode>[];
  final Map<String, List<CommentNode>> _replies = <String, List<CommentNode>>{};

  String _sort = 'top';
  bool _loading = true;
  bool _sending = false;
  bool _exhausted = false;
  Object? _error;
  String? _replyTo;

  String get _meId => sl<SocialRepository>().currentUserId ?? '';

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    setState(() {
      if (reset) _loading = _roots.isEmpty;
      _error = null;
      if (reset) _exhausted = false;
    });
    final cursor = reset || _roots.isEmpty ? null : _roots.last.createdAt;
    try {
      final page = await sl<FeedRepository>().comments(
        videoId: widget.videoId,
        shortId: widget.shortId,
        sort: _sort,
        beforeAt: cursor,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _roots.clear();
        _roots.addAll(page);
        _exhausted = page.length < 20;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadReplies(CommentNode comment) async {
    try {
      final page = await sl<FeedRepository>().comments(
        videoId: widget.videoId,
        shortId: widget.shortId,
        parentId: comment.id,
        sort: 'newest',
      );
      if (!mounted) return;
      setState(() => _replies[comment.id] = page);
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await sl<FeedRepository>().addComment(
        body: body,
        videoId: _replyTo == null ? widget.videoId : null,
        shortId: _replyTo == null ? widget.shortId : null,
        parentId: _replyTo,
      );
      if (!mounted) return;
      _composer.clear();
      final parent = _replyTo;
      setState(() => _replyTo = null);
      if (parent != null) {
        final target = _roots.firstWhere((c) => c.id == parent, orElse: () => _roots.first);
        await _loadReplies(target);
        if (mounted) {
          setState(() {
            final index = _roots.indexWhere((c) => c.id == parent);
            if (index >= 0) _roots[index] = _roots[index].copyWith(replyCount: _roots[index].replyCount + 1);
          });
        }
      } else {
        await _load(reset: true);
      }
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _like(CommentNode comment) async {
    final liked = !comment.likedByMe;
    _replace(comment.copyWith(likedByMe: liked, likeCount: (comment.likeCount + (liked ? 1 : -1)).clamp(0, 1 << 30)));
    try {
      await sl<FeedRepository>().likeComment(comment.id, like: liked);
    } catch (error) {
      _replace(comment);
      _toast(error);
    }
  }

  Future<void> _pin(CommentNode comment) async {
    try {
      await sl<FeedRepository>().pinComment(comment.id, pinned: !comment.isPinned);
      await _load(reset: true);
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _heart(CommentNode comment) async {
    try {
      await sl<FeedRepository>().heartComment(comment.id, hearted: !comment.isHearted);
      _replace(comment);
      await _load(reset: true);
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _delete(CommentNode comment) async {
    try {
      await sl<FeedRepository>().deleteComment(comment.id);
      if (!mounted) return;
      setState(() => _roots.removeWhere((c) => c.id == comment.id));
    } catch (error) {
      _toast(error);
    }
  }

  void _replace(CommentNode comment) {
    if (!mounted) return;
    setState(() {
      final index = _roots.indexWhere((c) => c.id == comment.id);
      if (index >= 0) _roots[index] = comment;
      final replies = _replies[comment.id];
      if (replies != null) {
        final replyIndex = replies.indexWhere((c) => c.id == comment.id);
        if (replyIndex >= 0) replies[replyIndex] = comment;
      }
    });
  }

  void _toast(Object error) {
    if (!mounted) return;
    final message = error is AppException ? error.message : 'Something went wrong.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _startReply(CommentNode comment) {
    setState(() => _replyTo = comment.id);
    _composerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        if (!widget.shrinkWrap)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: <Widget>[
                Text(
                  '${widget.totalCount > 0 ? widget.totalCount : _roots.length} comments',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _sort = _sort == 'top' ? 'newest' : 'top');
                    unawaited(_load(reset: true));
                  },
                  icon: Icon(_sort == 'top' ? Icons.local_fire_department_outlined : Icons.schedule_rounded, size: 18),
                  label: Text(_sort == 'top' ? 'Top' : 'Newest'),
                ),
              ],
            ),
          ),
        if (_loading)
          const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Center(child: CircularProgressIndicator()))
        else if (_error != null && _roots.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: EmptyState(
              title: 'Comments could not load',
              message: _error is AppException ? (_error! as AppException).message : 'Check your connection and retry.',
              icon: Icons.forum_outlined,
              action: FilledButton(onPressed: () => _load(reset: true), child: const Text('Retry')),
            ),
          )
        else if (_roots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: EmptyState(title: 'No comments yet', message: 'Be the first to say something.', icon: Icons.forum_outlined),
          )
        else
          ListView.builder(
            controller: widget.scrollController,
            shrinkWrap: widget.shrinkWrap,
            physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
            padding: widget.padding,
            itemCount: _roots.length,
            itemBuilder: (context, index) {
              final comment = _roots[index];
              final replies = _replies[comment.id];
              return _CommentTile(
                comment: comment,
                tags: comment.authorTags,
                replies: replies,
                meId: _meId,
                creatorId: widget.creatorId,
                canModerate: widget.creatorId != null && widget.creatorId == _meId,
                onLike: () => _like(comment),
                onReply: () => _startReply(comment),
                onPin: () => _pin(comment),
                onHeart: () => _heart(comment),
                onDelete: () => _delete(comment),
                onOpenReplies: () => _loadReplies(comment),
                onLikeReply: _like,
                onReplyToReply: _startReply,
              );
            },
          ),
        if (!_exhausted && _roots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton(
              onPressed: () => _load(reset: false),
              child: const Text('Show more comments'),
            ),
          ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant.withOpacity(0.5))),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_replyTo != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4, left: 4),
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.reply_rounded, size: 15),
                              const SizedBox(width: 5),
                              const Text('Replying to a comment', style: TextStyle(fontSize: 12)),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => setState(() => _replyTo = null),
                                child: const Text('Cancel', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      TextField(
                        controller: _composer,
                        focusNode: _composerFocus,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: _replyTo == null ? 'Add a comment…' : 'Write a reply…',
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.tags,
    required this.replies,
    required this.meId,
    required this.canModerate,
    this.creatorId,
    required this.onLike,
    required this.onReply,
    required this.onPin,
    required this.onHeart,
    required this.onDelete,
    required this.onOpenReplies,
    required this.onLikeReply,
    required this.onReplyToReply,
    this.isReply = false,
  });

  final CommentNode comment;
  final List<TagSummary> tags;
  final List<CommentNode>? replies;
  final String meId;
  final String? creatorId;
  final bool canModerate;
  final bool isReply;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onPin;
  final VoidCallback onHeart;
  final VoidCallback onDelete;
  final VoidCallback onOpenReplies;
  final void Function(CommentNode) onLikeReply;
  final void Function(CommentNode) onReplyToReply;

  bool get _isMine => comment.authorId != null && comment.authorId == meId;

  bool get _isCreator => creatorId != null && comment.authorId == creatorId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(isReply ? 44 : 14, isReply ? 6 : 10, 10, isReply ? 6 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              GestureDetector(
                onTap: comment.authorId == null ? null : () => context.push('/u/${comment.authorId}'),
                child: PersonAvatar(
                  name: comment.authorName ?? 'Someone',
                  path: comment.authorAvatarPath,
                  size: isReply ? 28 : 36,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: NameLine(
                            name: comment.authorName ?? 'Someone',
                            handle: handleOf(comment.authorUsername, comment.authorDiscriminator),
                            tags: tags,
                            verified: comment.authorVerified,
                            maxTags: 1,
                            style: TextStyle(fontSize: isReply ? 12.5 : 13.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (comment.isPinned) ...<Widget>[
                          const SizedBox(width: 6),
                          const BadgePill(label: 'Pinned', icon: Icons.push_pin_rounded),
                        ],
                        if (_isCreator) ...<Widget>[
                          const SizedBox(width: 6),
                          const BadgePill(label: 'Creator', icon: Icons.movie_rounded, color: Brand.seed),
                        ],
                        if (comment.isHearted) ...<Widget>[
                          const SizedBox(width: 6),
                          const BadgePill(label: 'Hearted', icon: Icons.favorite_rounded, color: Brand.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(comment.body, style: const TextStyle(fontSize: 14, height: 1.35)),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Text(
                          ChatFormatting.listStamp(comment.createdAt),
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: onLike,
                          child: Row(
                            children: <Widget>[
                              Icon(
                                comment.likedByMe ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                size: 15,
                                color: comment.likedByMe ? Brand.accent : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                compactCount(comment.likeCount),
                                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: onReply,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Reply', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                        const Spacer(),
                        if (canModerate)
                          PopupMenuButton<String>(
                            tooltip: 'Moderate',
                            icon: Icon(Icons.more_horiz_rounded, size: 18, color: scheme.onSurfaceVariant),
                            onSelected: (value) {
                              if (value == 'pin') onPin();
                              if (value == 'heart') onHeart();
                              if (value == 'delete') onDelete();
                            },
                            itemBuilder: (context) => <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                value: 'pin',
                                child: Text(comment.isPinned ? 'Unpin' : 'Pin to top'),
                              ),
                              PopupMenuItem<String>(
                                value: 'heart',
                                child: Text(comment.isHearted ? 'Remove heart' : 'Heart as creator'),
                              ),
                              const PopupMenuItem<String>(value: 'delete', child: Text('Remove comment')),
                            ],
                          )
                        else if (_isMine)
                          IconButton(
                            tooltip: 'Delete',
                            onPressed: onDelete,
                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (replies == null && comment.replyCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 46, top: 2),
              child: TextButton(
                onPressed: onOpenReplies,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'View ${comment.replyCount} ${comment.replyCount == 1 ? 'reply' : 'replies'}',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          if (replies != null)
            for (final reply in replies!)
              _CommentTile(
                comment: reply,
                tags: reply.authorTags,
                replies: null,
                meId: meId,
                creatorId: creatorId,
                canModerate: canModerate,
                isReply: true,
                onLike: () => onLikeReply(reply),
                onReply: () => onReplyToReply(reply),
                onPin: () {},
                onHeart: () {},
                onDelete: () {},
                onOpenReplies: () {},
                onLikeReply: onLikeReply,
                onReplyToReply: onReplyToReply,
              ),
        ],
      ),
    );
  }
}

/// The short-form flavour: a draggable sheet over the reel.
Future<void> showCommentsSheet(
  BuildContext context, {
  String? videoId,
  String? shortId,
  int totalCount = 0,
  String? creatorId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.72,
        child: CommentsPanel(
          videoId: videoId,
          shortId: shortId,
          totalCount: totalCount,
          creatorId: creatorId,
        ),
      ),
    ),
  );
}
