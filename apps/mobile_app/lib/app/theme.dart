import 'package:flutter/material.dart';

/// One source of truth for chat visuals, because a bubble's corner radius and tail
/// have to agree with the avatar's and with the composer, and the read-receipt
/// colour has to survive both themes.
class AppTheme {
  const AppTheme._();

  static const String fontFamily = 'Roboto';

  static const Color seed = Color(0xFF2AABEE);
  static const Color mineBubble = Color(0xFFEFF9FE);
  static const Color mineBubbleDark = Color(0xFF16323F);
  static const Color tickActive = Color(0xFF4FB0F0);
  static const Color danger = Color(0xFFE5534B);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.light ? const Color(0xFFF4F6F8) : const Color(0xFF131519),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: brightness == Brightness.light ? Colors.white : const Color(0xFF1A1D22),
        foregroundColor: scheme.onSurface,
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4)),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: brightness == Brightness.light ? Colors.white : const Color(0xFF21252B),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: scheme.outlineVariant)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
    );
  }

  static BorderRadius bubbleRadius(bool isMine) => BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: Radius.circular(isMine ? 16 : 5),
        bottomRight: Radius.circular(isMine ? 5 : 16),
      );

  static Color bubbleColor(BuildContext context, {required bool isMine, bool isTelegramMirror = false}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (isTelegramMirror) {
      // A mirrored bubble is intentionally tinted: the same words arrived through
      // Telegram, and the user should be able to tell without long-pressing it.
      return dark ? const Color(0xFF1C2A22) : const Color(0xFFF0FAF3);
    }
    if (isMine) return dark ? mineBubbleDark : mineBubble;
    return dark ? const Color(0xFF1F2329) : Colors.white;
  }
}
