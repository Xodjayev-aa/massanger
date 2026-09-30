import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_bloc.dart';
import '../features/auth/gate_page.dart';
import '../features/auth/sign_in_page.dart';
import '../features/bots/bots_page.dart';
import '../features/chat/chat_page.dart';
import '../features/chats/chats_page.dart';
import '../features/chats/new_chat_page.dart';
import '../features/chats/search_page.dart';
import '../features/communities/communities_page.dart';
import '../features/create/create_page.dart';
import '../features/economy/store_page.dart';
import '../features/home/home_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/profile/profile_page.dart';
import '../features/profile/user_page.dart';
import '../features/reels/reels_page.dart';
import '../features/search/global_search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/telegram/link_page.dart';
import '../features/telegram/telegram_page.dart';
import '../features/watch/watch_page.dart';
import 'shell.dart';

/// Route literals live here so a redirect and a deep link can never disagree
/// about spelling.
///
/// Two zones, on purpose:
///
/// * **Inside the shell** — the five bottom-bar branches (Home, Reels, Create,
///   Messages, Profile). Each keeps its own stack, so switching tabs never
///   loses a scroll position.
/// * **Over the shell** — everything that opens on top of the bar: a video, a
///   reel, a channel, a chat, search, the store. Those are plain root routes,
///   which is what makes a share link work with no session history and keeps
///   the bar from flashing while a screen loads.
class Routes {
  const Routes._();

  static const String root = '/';
  static const String signIn = '/sign-in';
  static const String gate = '/gate';

  // Shell branches.
  static const String home = '/home';
  static const String reels = '/reels';
  static const String create = '/create';
  static const String messages = '/messages';
  static const String me = '/me';

  // Over the bar.
  static const String search = '/search';
  static const String notifications = '/notifications';
  static const String store = '/store';
  static const String wallet = '/wallet';
  static const String communities = '/communities';
  static const String bots = '/bots';
  static const String settings = '/settings';
  static const String telegram = '/telegram';
  static const String telegramLink = '/telegram/link';

  // Chat surfaces, kept on their historical paths so a link shared yesterday
  // still opens the thread today.
  static const String chats = '/chats';
  static const String chatSearch = '/chats/search';
  static const String newChatPath = '/chats/new';

  static String watch(String videoId) => '/watch/$videoId';
  static String shortWatch(String shortId) => '/watch/short/$shortId';
  static String sound(String soundId) => '/sound/$soundId';
  static String user(String userId) => '/u/$userId';
  static String chat(String chatId) => '$chats/$chatId';
  static String community(String communityId) => '$communities/$communityId';
  static String bot(String botId) => '$bots/$botId';

  /// `/reels?tab=following` — the toggle writes the tab into the URL so a
  /// reload or a shared link opens the same feed.
  static String reelsTab(String tab) => tab == 'for_you' ? reels : '$reels?tab=$tab';

  static String newChat({String? username}) =>
      username == null ? newChatPath : '$newChatPath?username=$username';
}

/// [auth] drives the redirect: an authenticated user never sees the sign-in
/// page, and a server-blocked account never sees a chat.
///
/// [refresh] is a separate listenable because go_router asks for a
/// `Listenable` while a bloc is a stream; the app bridges one to the other so
/// the bloc stays the single source of truth and the router is still built
/// exactly once.
GoRouter buildRouter(AuthBloc auth, Listenable refresh) {
  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    // The two paths the web build is allowed to be entered on: the site root
    // (OAuth callback, PWA start URL) and anything already typed.
    redirect: (context, state) {
      final status = auth.state.status;
      final location = state.matchedLocation;

      switch (status) {
        case AppStatus.unknown:
          // Still restoring the session: leave the stack alone, the splash
          // covers it.
          return null;
        case AppStatus.signedOut:
          return location == Routes.signIn ? null : Routes.signIn;
        case AppStatus.verificationRequired:
        case AppStatus.blocked:
          return location == Routes.gate ? null : Routes.gate;
        case AppStatus.ready:
          // Pushed back out of the entry screens once access is granted.
          if (location == Routes.signIn || location == Routes.gate || location == Routes.root) {
            return Routes.home;
          }
          // The old chat-first entry point keeps working: `/chats` is the
          // Messages tab now.
          if (location == Routes.chats) return Routes.messages;
          return null;
      }
    },
    routes: <RouteBase>[
      // The site root has to be a real route: Vercel rewrites `/` and nested
      // paths to index.html, and without this an OAuth return would hit the
      // error page before the session redirect runs.
      GoRoute(path: Routes.root, builder: (context, state) => const _BootSplash()),
      GoRoute(path: Routes.signIn, builder: (context, state) => const SignInPage()),
      GoRoute(path: Routes.gate, builder: (context, state) => const GatePage()),

      // ---------------------------------------------------------------- shell
      // Branch order is the bar order: Home, Reels, Create, Messages, Profile.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(path: Routes.home, builder: (context, state) => const HomePage()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.reels,
                builder: (context, state) => ReelsPage(
                  initialTab: state.uri.queryParameters['tab'] ?? 'for_you',
                  authorId: state.uri.queryParameters['author'],
                  soundId: state.uri.queryParameters['sound'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.create,
                builder: (context, state) => CreatePage(
                  initialKind: state.uri.queryParameters['kind'] ?? 'video',
                  replyTo: state.uri.queryParameters['replyTo'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(path: Routes.messages, builder: (context, state) => const ChatsPage()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(path: Routes.me, builder: (context, state) => const ProfilePage()),
            ],
          ),
        ],
      ),

      // -------------------------------------------------- over the bottom bar
      GoRoute(path: Routes.search, builder: (context, state) => const GlobalSearchPage()),
      GoRoute(path: Routes.notifications, builder: (context, state) => const NotificationsPage()),
      GoRoute(path: Routes.store, builder: (context, state) => const StorePage()),
      GoRoute(path: Routes.wallet, builder: (context, state) => const WalletPage()),
      GoRoute(path: Routes.settings, builder: (context, state) => const SettingsPage()),
      GoRoute(path: Routes.telegram, builder: (context, state) => const TelegramPage()),
      GoRoute(path: Routes.telegramLink, builder: (context, state) => const LinkPage()),
      GoRoute(path: Routes.communities, builder: (context, state) => const CommunitiesPage()),
      GoRoute(
        path: Routes.community(':id'),
        builder: (context, state) => CommunityPage(communityId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(path: Routes.bots, builder: (context, state) => const BotsPage()),
      GoRoute(
        path: Routes.bot(':id'),
        builder: (context, state) => BotBuilderPage(botId: state.pathParameters['id']),
      ),

      // A short's own page comes before `/watch/:id` so the literal segment
      // `short` is never parsed as an id.
      GoRoute(
        path: '/watch/short/:id',
        builder: (context, state) => ShortWatchPage(shortId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/watch/:id',
        builder: (context, state) => WatchPage(videoId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/sound/:id',
        builder: (context, state) => SoundPage(soundId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/u/:id',
        builder: (context, state) => UserPage(userId: state.pathParameters['id'] ?? ''),
      ),

      // Chats. `/chats/search` is a literal so it can never be read as a chat
      // id, and `new` likewise.
      GoRoute(path: Routes.chatSearch, builder: (context, state) => const SearchPage()),
      GoRoute(
        path: Routes.newChatPath,
        builder: (context, state) =>
            NewChatPage(preferredUsername: state.uri.queryParameters['username']),
      ),
      GoRoute(
        path: '/chats/:id',
        builder: (context, state) => ChatPage(chatId: state.pathParameters['id'] ?? ''),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(),
      body: Center(child: Text('Nothing here: ${state.uri}')),
    ),
  );
}

/// Shown while the session is still unknown, including the moment Google
/// returns to the site root. The router leaves this screen once auth resolves.
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
