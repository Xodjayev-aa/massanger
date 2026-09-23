import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_bloc.dart';
import '../features/auth/gate_page.dart';
import '../features/auth/sign_in_page.dart';
import '../features/chat/chat_page.dart';
import '../features/chats/chats_page.dart';
import '../features/chats/new_chat_page.dart';
import '../features/chats/search_page.dart';
import '../features/profile/profile_page.dart';
import '../features/telegram/link_page.dart';
import '../features/telegram/telegram_page.dart';

/// Route literals live here so a redirect and a deep link can never disagree about
/// spelling.
class Routes {
  const Routes._();

  static const String signIn = '/sign-in';
  static const String gate = '/gate';
  static const String chats = '/chats';
  static const String search = '/search';
  static const String telegram = '/telegram';
  static const String telegramLink = '/telegram/link';
  static const String profile = '/me';

  static String chat(String chatId) => '$chats/$chatId';
  static String newChat({String? username}) => username == null ? '$chats/new' : '$chats/new?username=$username';
}

/// [auth] drives the redirect: an authenticated user never sees the sign-in page,
/// and a user the age gate has not cleared never sees a chat.
GoRouter buildRouter(AuthBloc auth) {
  return GoRouter(
    initialLocation: Routes.chats,
    // The bloc is a ChangeNotifier, so a sign-in, a token expiry or a passing age
    // check re-runs `redirect` without any screen having to remember to navigate.
    refreshListenable: auth,
    redirect: (context, state) {
      final status = auth.state.status;
      final location = state.matchedLocation;

      switch (status) {
        case AppStatus.unknown:
          // Still restoring the session: leave the stack alone, the splash covers it.
          return null;
        case AppStatus.signedOut:
          return location == Routes.signIn ? null : Routes.signIn;
        case AppStatus.verificationRequired:
        case AppStatus.blocked:
          return location == Routes.gate ? null : Routes.gate;
        case AppStatus.ready:
          // Pushed back out of the gate/sign-in screens once access is granted.
          if (location == Routes.signIn || location == Routes.gate) return Routes.chats;
          return null;
      }
    },
    routes: <RouteBase>[
      GoRoute(path: Routes.signIn, builder: (context, state) => const SignInPage()),
      GoRoute(path: Routes.gate, builder: (context, state) => const GatePage()),
      GoRoute(path: Routes.search, builder: (context, state) => const SearchPage()),
      GoRoute(path: Routes.telegram, builder: (context, state) => const TelegramPage()),
      GoRoute(path: Routes.telegramLink, builder: (context, state) => const LinkPage()),
      GoRoute(path: Routes.profile, builder: (context, state) => const ProfilePage()),
      GoRoute(
        path: Routes.chats,
        builder: (context, state) => const ChatsPage(),
        routes: <RouteBase>[
          // Children keep '/chats/new' and '/chats/:id' from competing: a literal
          // segment is matched before the parameter, and both stay under one shell.
          GoRoute(
            path: 'new',
            builder: (context, state) => NewChatPage(preferredUsername: state.uri.queryParameters['username']),
          ),
          GoRoute(
            path: ':id',
            builder: (context, state) => ChatPage(chatId: state.pathParameters['id'] ?? ''),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(),
      body: Center(child: Text('Nothing here: ${state.uri}')),
    ),
  );
}
