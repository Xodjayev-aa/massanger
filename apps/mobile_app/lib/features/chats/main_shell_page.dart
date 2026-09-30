import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/discord_markdown.dart';
import '../../core/errors.dart';
import '../../data/shorts_repository.dart';
import '../../data/telegram_repository.dart';
import '../../data/video_repository.dart';
import '../chats/chats_bloc.dart';
import '../chats/chats_page.dart';
import '../profile/profile_page.dart';
import 'shorts_page.dart';
import 'youtube_feed_page.dart';

/// Next-Gen Master Scaffold combining:
/// 1. Top App Bar: YouTube + TikTok Hybrid (Logo + Realtime Status + Search + Profile)
/// 2. Dual Feed Filters: [ 🎥 Videos ] (YouTube 16:9) vs [ ⚡ Shorts / Reels ] (TikTok 9:16)
/// 3. Bottom Navigation: TikTok Control Panel Hybrid (Home, Shorts, [+] Action, Messages/Servers, You)
class MainShellPage extends StatefulWidget {
  const MainShellPage({super.key});

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage> {
  int _currentIndex = 0; // 0: Home/Videos, 1: Shorts, 2: Create (modal), 3: Messages, 4: Profile
  int _feedFormatIndex = 0; // 0: Videos (YouTube), 1: Shorts (TikTok)

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chatsState = context.watch<ChatsBloc>().state;
    final totalUnread = chatsState.totalUnread;

    return Scaffold(
      appBar: _buildTopAppBar(context),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _currentIndex,
          children: <Widget>[
            // Tab 0: Home with Dual Formats (YouTube Videos vs TikTok Shorts)
            _buildHomeFeed(),
            // Tab 1: Immersive Fullscreen Shorts Feed
            const ShortsPage(),
            // Tab 2: Placeholder for [+] Upload modal
            const SizedBox.shrink(),
            // Tab 3: Telegram & Discord Messages
            const ChatsPageBody(),
            // Tab 4: Profile
            const ProfilePage(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomControlBar(context, totalUnread),
    );
  }

  PreferredSizeWidget _buildTopAppBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: <Widget>[
          // Brand Logo with Live Pulse
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFFFF0000), Color(0xFF5865F2)], // YouTube Red to Discord Blurple
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                SizedBox(width: 4),
                Text(
                  'MessengerX',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Live Realtime Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF31C753).withAlpha(30),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF31C753).withAlpha(120), width: 0.8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CircleAvatar(radius: 3, backgroundColor: Color(0xFF31C753)),
                SizedBox(width: 4),
                Text(
                  'LIVE',
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF31C753)),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: <Widget>[
        IconButton(
          tooltip: 'Search #channels, @users, videos',
          icon: const Icon(Icons.search_rounded),
          onPressed: () => context.push(Routes.search),
        ),
        IconButton(
          tooltip: 'Notifications',
          icon: const Badge(
            smallSize: 8,
            child: Icon(Icons.notifications_outlined),
          ),
          onPressed: () {},
        ),
        IconButton(
          tooltip: 'Telegram Bridge',
          icon: const Icon(Icons.send_rounded, size: 20),
          onPressed: () => context.push(Routes.telegram),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildHomeFeed() {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        // Dual Content Filter Bar: [ 🎥 Videos ] vs [ ⚡ Shorts ]
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant.withAlpha(40))),
          ),
          child: Row(
            children: <Widget>[
              ChoiceChip(
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.video_collection_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Videos (YouTube)'),
                  ],
                ),
                selected: _feedFormatIndex == 0,
                onSelected: (val) {
                  if (val) setState(() => _feedFormatIndex = 0);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.bolt_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Shorts / Reels'),
                  ],
                ),
                selected: _feedFormatIndex == 1,
                onSelected: (val) {
                  if (val) setState(() => _feedFormatIndex = 1);
                },
              ),
            ],
          ),
        ),

        // Display Chosen Feed Format
        Expanded(
          child: _feedFormatIndex == 0 ? const YouTubeFeedPage() : const ShortsPage(),
        ),
      ],
    );
  }

  Widget _buildBottomControlBar(BuildContext context, int totalUnread) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withAlpha(50))),
      ),
      child: NavigationBar(
        selectedIndex: _currentIndex == 2 ? 0 : _currentIndex,
        onDestinationSelected: (index) {
          if (index == 2) {
            _showUploadActionSheet(context);
          } else {
            setState(() => _currentIndex = index);
          }
        },
        destinations: <Widget>[
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.smart_display_outlined),
            selectedIcon: Icon(Icons.smart_display_rounded),
            label: 'Shorts',
          ),
          // TikTok Style Center [+] Action Button
          NavigationDestination(
            icon: Container(
              width: 44,
              height: 30,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFF00F2FE), Color(0xFF4FACFE)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 22),
            ),
            label: '',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: totalUnread > 0,
              label: Text('$totalUnread'),
              child: const Icon(Icons.chat_bubble_outline_rounded),
            ),
            selectedIcon: Badge(
              isLabelVisible: totalUnread > 0,
              label: Text('$totalUnread'),
              child: const Icon(Icons.chat_bubble_rounded),
            ),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'You',
          ),
        ],
      ),
    );
  }

  void _showUploadActionSheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('Create & Connect', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.red.withAlpha(30), shape: BoxShape.circle),
                  child: const Icon(Icons.bolt_rounded, color: Colors.red),
                ),
                title: const Text('Create Short / Reel (TikTok)', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Vertical 9:16 clip up to 60 seconds'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickAndUploadVideo(feedType: 'short');
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFFF0000).withAlpha(30), shape: BoxShape.circle),
                  child: const Icon(Icons.video_library_rounded, color: Color(0xFFFF0000)),
                ),
                title: const Text('Upload Long Video (YouTube)', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('16:9 full-length video with title & description'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickAndUploadVideo(feedType: 'long');
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFF5865F2).withAlpha(30), shape: BoxShape.circle),
                  child: const Icon(Icons.forum_rounded, color: Color(0xFF5865F2)),
                ),
                title: const Text('New Chat or Discord Channel', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Telegram direct chat or server #channel'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(Routes.newChat());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadVideo({required String feedType}) async {
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null || !mounted) return;

      String? title;
      String? desc;

      if (feedType == 'long') {
        final titleController = TextEditingController();
        final descController = TextEditingController();
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dContext) => AlertDialog(
            title: const Text('Video Details'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: titleController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Title', hintText: 'Enter video title'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Description', hintText: 'Use #hashtags and @mentions'),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.of(dContext).pop(false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.of(dContext).pop(true), child: const Text('Publish')),
            ],
          ),
        );
        if (confirmed != true) return;
        title = titleController.text.trim();
        desc = descController.text.trim();
      }

      final scaffold = ScaffoldMessenger.of(context);
      scaffold.showSnackBar(const SnackBar(content: Text('Publishing video to Backblaze B2...')));

      await sl<ShortsRepository>().publish(
        file: picked,
        title: title,
        description: desc,
        caption: title ?? desc,
        feedType: feedType,
      );

      scaffold.showSnackBar(const SnackBar(content: Text('Video published successfully!')));
    } on AppException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed.')));
    }
  }
}

/// Standalone body for Chats with Discord/Telegram view switcher
class ChatsPageBody extends StatelessWidget {
  const ChatsPageBody({super.key});

  @override
  Widget build(BuildContext context) {
    return const ChatsPage();
  }
}
