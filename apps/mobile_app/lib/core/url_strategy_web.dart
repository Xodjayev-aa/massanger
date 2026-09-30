// Path strategy is web-only. The stub is used on Android and iOS.
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';
// ignore: avoid_web_libraries_in_flutter
import 'package:flutter_web_plugins/url_strategy.dart';

@JS('window.open')
external JSObject? _windowOpen(JSString url, JSString target, JSString features);

/// Use `/chats/:id` instead of `/#/chats/:id` so a Vercel rewrite of a nested
/// reload reaches the same GoRouter location the user had open.
void configureAppUrlStrategy() {
  usePathUrlStrategy();
}

bool openBrowserDownloadUrl(String url) {
  _windowOpen(url.toJS, '_blank'.toJS, 'noopener,noreferrer'.toJS);
  return true;
}
