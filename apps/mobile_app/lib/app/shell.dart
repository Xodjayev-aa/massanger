import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'brand.dart';

/// Lets a screen inside the shell decide whether the bars belong on screen.
///
/// The reels tab needs this: swiping a full-screen short should hide the bottom
/// bar (and restore it the moment the swipe ends), exactly like TikTok. Rather
/// than reaching up through the widget tree with a global key, the shell exposes
/// one notifier and the reels page asks for it.
class NavChrome extends InheritedWidget {
  const NavChrome({super.key, required this.hidden, required super.child});

  /// True while a screen wants the bars out of the way (reels, full-screen).
  final ValueNotifier<bool> hidden;

  static ValueNotifier<bool>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NavChrome>()?.hidden;

  /// Hides the bars from inside the shell. A no-op outside it, so a deep link
  /// straight into a short still renders with bars instead of throwing.
  static void setHidden(BuildContext context, bool value) {
    maybeOf(context)?.value = value;
  }

  @override
  bool updateShouldNotify(NavChrome oldWidget) => oldWidget.hidden != hidden;
}

/// The five-slot shell: Home, Reels, Create, Messages, Profile.
///
/// [navigationShell] is go_router's `StatefulNavigationShell`, so each tab keeps
/// its own scroll position and its own navigation stack — switching to Messages
/// and back must not rebuild the feed, and opening a chat must not lose the list.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hidden.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (_hidden.value) _hidden.value = false;
    widget.navigationShell.goBranch(
      index,
      // Tapping the tab you are already on returns to that tab's root — the
      // behaviour people expect from a bottom bar.
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NavChrome(
      hidden: _hidden,
      child: Scaffold(
        body: widget.navigationShell,
        bottomNavigationBar: ValueListenableBuilder<bool>(
          valueListenable: _hidden,
          builder: (context, hidden, child) => AnimatedSlide(
            offset: hidden ? const Offset(0, 1) : Offset.zero,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: hidden ? const SizedBox(width: double.infinity) : child,
            ),
          ),
          child: _BottomBar(
            index: widget.navigationShell.currentIndex,
            onSelect: _go,
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onSelect});

  final int index;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1115) : Colors.white,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withOpacity(isDark ? 0.25 : 0.6))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              _BarItem(
                icon: Icons.home_rounded,
                outline: Icons.home_outlined,
                label: 'Home',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              _BarItem(
                icon: Icons.play_circle_fill_rounded,
                outline: Icons.play_circle_outline_rounded,
                label: 'Reels',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              _CreateSlot(onTap: () => onSelect(2)),
              _BarItem(
                icon: Icons.forum_rounded,
                outline: Icons.forum_outlined,
                label: 'Messages',
                selected: index == 3,
                onTap: () => onSelect(3),
              ),
              _BarItem(
                icon: Icons.person_rounded,
                outline: Icons.person_outline_rounded,
                label: 'Profile',
                selected: index == 4,
                onTap: () => onSelect(4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.icon,
    required this.outline,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData outline;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = selected ? Brand.seed : scheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(selected ? icon : outline, size: 25, color: active),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: active,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The middle slot is the only raised control in the bar: a gradient square.
class _CreateSlot extends StatelessWidget {
  const _CreateSlot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Semantics(
          button: true,
          label: 'Create',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 44,
              height: 31,
              decoration: BoxDecoration(
                gradient: Brand.gradient,
                borderRadius: BorderRadius.circular(11),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: Brand.seed.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4)),
                ],
              ),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}
