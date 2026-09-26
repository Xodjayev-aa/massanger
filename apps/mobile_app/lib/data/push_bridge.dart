/// The browser-notification bridge, chosen per platform.
///
/// On the web this talks to `web/push/push-client.js`; everywhere else it is a
/// no-op that reports the feature as unsupported. The condition mirrors
/// `core/url_strategy.dart` (`dart.library.html`) so both platform switches in
/// this app are spelled the same way.
library;

export 'push_bridge_stub.dart' if (dart.library.html) 'push_bridge_web.dart';
export 'push_bridge_types.dart';
