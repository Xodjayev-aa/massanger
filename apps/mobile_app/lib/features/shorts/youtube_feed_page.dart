import 'package:flutter/material.dart';

import '../../app/di.dart';
import '../../core/errors.dart';
import '../../data/shorts_repository.dart';
import 'video_card.dart';

/// YouTube-style Home Video Feed:
/// - Top sub-bar: TikTok-style sliding switcher [Following] vs [For You]
/// - Dual format pills: [ 🎥 Videos ] vs [ ⚡ Shorts ]
/// - Full list of YouTube-style video cards with thumbnails, view count, badges
class YouTubeFeedPage extends StatefulWidget {
  const YouTubeFeedPage({super.key});

  @override
  State<YouTubeFeedPage> createState() => _YouTubeFeedPageState();
}

class _YouTubeFeedPageState extends State<YouTubeFeedPage> with SingleTickerProviderStateMixin {
  final ShortsRepository _shorts = sl<ShortsRepository>();
  late TabController _tabController;

  List<ShortVideo> _videos = <ShortVideo>[];
  bool _loading = true;
  Object? _error;
  bool _following = false; // false = FYP, true = Following

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _following = _tabController.index == 0;
        });
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _shorts.page(
        feedType: 'long',
        followingOnly: _following,
      );
      if (!mounted) return;
      setState(() {
        _videos = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: <Widget>[
        // TikTok-Style Feed Switcher Header (Following vs For You)
        Container(
          height: 44,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant.withAlpha(50))),
          ),
          child: TabBar(
            controller: _tabController,
            indicatorColor: scheme.primary,
            indicatorWeight: 3,
            labelColor: scheme.onSurface,
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            tabs: const <Widget>[
              Tab(text: 'Following'),
              Tab(text: 'For You'),
            ],
          ),
        ),

        // Videos Content Body
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(AppException.wrap(_error!).message),
                          const SizedBox(height: 8),
                          FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
                        ],
                      ),
                    )
                  : _videos.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(Icons.video_library_outlined, size: 52, color: scheme.outline),
                                const SizedBox(height: 12),
                                Text(
                                  _following
                                      ? 'No videos from people you follow yet'
                                      : 'No videos published yet',
                                  style: theme.textTheme.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Tap the center + button to upload the first video.',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            itemCount: _videos.length,
                            separatorBuilder: (context, index) => const Divider(height: 1, thickness: 1),
                            itemBuilder: (context, index) => VideoCard(video: _videos[index]),
                          ),
                        ),
        ),
      ],
    );
  }
}
