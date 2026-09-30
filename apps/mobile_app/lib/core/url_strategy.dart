import 'url_strategy_stub.dart' if (dart.library.html) 'url_strategy_web.dart' as strategy;

/// Configure browser paths before `runApp`. No-op on Android and iOS.
void configureAppUrlStrategy() => strategy.configureAppUrlStrategy();

/// Opens a signed attachment download URL in the browser. Returns false on
/// native platforms where browser downloads are unsupported.
bool openBrowserDownloadUrl(String url) => strategy.openBrowserDownloadUrl(url);
