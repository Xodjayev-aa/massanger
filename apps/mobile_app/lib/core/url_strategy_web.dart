// Path strategy is web-only. The stub is used on Android and iOS.
// ignore: avoid_web_libraries_in_flutter
import 'package:flutter_web_plugins/url_strategy.dart';

/// Use `/chats/:id` instead of `/#/chats/:id` so a Vercel rewrite of a nested
/// reload reaches the same GoRouter location the user had open.
void configureAppUrlStrategy() {
  usePathUrlStrategy();
}
