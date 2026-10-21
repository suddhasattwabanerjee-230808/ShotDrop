import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets.dart';
import 'app_screens.dart';
import 'card_screen.dart';
import 'selected_screen.dart';
import 'settings_screen.dart';
import 'upload_screen.dart';

enum HomeTab { gallery, selected, upload, settings }

/// Space to leave at the end of a tab's scrolling content so its last row
/// can scroll clear of the floating bar.
const navBarClearance = 96.0;

/// The app's home: four tabs (Gallery, Selected, Upload, Settings) under a
/// rounded bar that floats at the bottom centre. Each tab keeps its place
/// while another is open. Screens opened from a tab (viewer, editor) cover
/// the bar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Switches to [tab] from anywhere inside the shell.
  static void go(BuildContext context, HomeTab tab) =>
      context.findAncestorStateOfType<_HomeShellState>()?._go(tab);

  /// Set while a tab wants the bar out of the way (picking photos in the Gallery).
  static final hidden = ValueNotifier<bool>(false);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  HomeTab _tab = HomeTab.gallery;
  late final _updater = AppScope.of(context).updater;
  bool _toldUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updater.addListener(_onUpdate);
      _onUpdate();
    });
  }

  @override
  void dispose() {
    _updater.removeListener(_onUpdate);
    super.dispose();
  }

  void _go(HomeTab tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    HomeShell.hidden.value = false;
    setState(() => _tab = tab);
  }

  /// A new version: say so once, with the way to get it.
  void _onUpdate() {
    final latest = _updater.latest;
    if (_toldUpdate || latest == null || !mounted) return;
    _toldUpdate = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        persist: false,
        content: Text('ShotDrop ${latest.version} is out'),
        action: SnackBarAction(label: 'Update', onPressed: () => showUpdateSheet(context)),
      ),
    );
  }

  // One Scaffold around the tabs (theirs sit inside it), so a SnackBar shows
  // once, just above the bar; and extendBody lets each tab run under the bar
  // while its own SafeArea / bottom bar makes room for it.
  @override
  Widget build(BuildContext context) => PopScope(
    // Back from another tab goes to the Gallery first.
    canPop: _tab == HomeTab.gallery,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _go(HomeTab.gallery);
    },
    child: Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _tab.index,
        children: const [CardScreen(), SelectedScreen(), UploadScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: HomeShell.hidden,
        builder: (context, hidden, _) => AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: hidden
              ? const SizedBox(width: double.infinity)
              : SafeArea(
                  top: false,
                  child: Center(heightFactor: 1, child: _NavBar(tab: _tab, onTap: _go)),
                ),
        ),
      ),
    ),
  );
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.tab, required this.onTap});
  final HomeTab tab;
  final ValueChanged<HomeTab> onTap;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(34),
          boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(34),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: surfaceHigh.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(34),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: ListenableBuilder(
                listenable: Listenable.merge([scope.uploads, scope.updater]),
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NavItem(
                      icon: Icons.photo_library_outlined,
                      activeIcon: Icons.photo_library_rounded,
                      label: 'Gallery',
                      selected: tab == HomeTab.gallery,
                      onTap: () => onTap(HomeTab.gallery),
                    ),
                    _NavItem(
                      icon: Icons.favorite_border_rounded,
                      activeIcon: Icons.favorite_rounded,
                      label: 'Selected',
                      count: scope.uploads.selected.length + scope.uploads.copying,
                      selected: tab == HomeTab.selected,
                      onTap: () => onTap(HomeTab.selected),
                    ),
                    _NavItem(
                      icon: Icons.outbox_outlined,
                      activeIcon: Icons.outbox_rounded,
                      label: 'Upload',
                      count: scope.uploads.queued.length,
                      selected: tab == HomeTab.upload,
                      onTap: () => onTap(HomeTab.upload),
                    ),
                    _NavItem(
                      icon: Icons.settings_outlined,
                      activeIcon: Icons.settings_rounded,
                      label: 'Settings',
                      dot: scope.updater.available,
                      selected: tab == HomeTab.settings,
                      onTap: () => onTap(HomeTab.settings),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab: just its icon, or, when it's the open one, a yellow pill with
/// the icon and its name.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
    this.dot = false,
  });

  final IconData icon, activeIcon;
  final String label;
  final bool selected, dot;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: selected ? 18 : 16),
        decoration: BoxDecoration(color: selected ? accent : Colors.transparent, borderRadius: BorderRadius.circular(28)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: count > 0 || dot,
              smallSize: 9,
              label: count > 0 ? Text('$count') : null,
              backgroundColor: selected ? onAccent : accent,
              textColor: selected ? accent : onAccent,
              offset: const Offset(8, -6),
              child: Icon(selected ? activeIcon : icon, color: selected ? onAccent : ink, size: 24),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        label,
                        style: const TextStyle(color: onAccent, fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    ),
  );
}
