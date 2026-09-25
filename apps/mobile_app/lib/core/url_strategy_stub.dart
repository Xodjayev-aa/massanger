/// VM/native no-op. Web builds use the path strategy so reloads of `/chats/...`
/// survive a static host that rewrites unknown paths to `index.html`.
void configureAppUrlStrategy() {}
