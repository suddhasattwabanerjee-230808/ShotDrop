import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_channel.dart';
import '../prefetch.dart';
import '../props.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets.dart';
import 'app_screens.dart';
import 'card_screen.dart';
import 'phone_screen.dart';
import 'publish_screen.dart';
import 'selected_screen.dart';
import 'settings_screen.dart';
import 'upload_screen.dart';

enum HomeTab { gallery, phone, selected, upload, settings }

/// Space to leave at the end of a tab's scrolling content so its last row
/// can scroll clear of the floating bar.
const navBarClearance = 96.0;

/// The app's home: five tabs (SD Card Gallery, Phone Gallery, Selected,
/// Upload, Settings) under a
/// rounded bar that floats at the bottom centre. Each tab keeps its place
/// while another is open. Screens opened from a tab (viewer, editor) cover
/// the bar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Switches to [tab] from anywhere inside the shell.
  static void go(BuildContext context, HomeTab tab) => context.findAncestorStateOfType<_HomeShellState>()?._go(tab);

  /// Set while a tab wants the bar out of the way (picking photos in the Gallery).
  static final hidden = ValueNotifier<bool>(false);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  HomeTab _tab = HomeTab.gallery;
  late final _scope = AppScope.of(context);
  late final _updater = _scope.updater;
  bool _toldUpdate = false;
  Timer? _tidy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppChannel.instance.cardPlugged.addListener(_onCardPlugged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updater.addListener(_onUpdate);
      _onUpdate();
      // Closed while Instagram was open: ask now.
      PublishScreen.showIfPending(context);
    });
    // Tidy up once the app has settled, out of the way of the first screens.
    _tidy = Timer(const Duration(seconds: 8), () {
      if (mounted && _scope.settings.autoTidy) tidyStorage(_scope.uploads, _scope.settings).ignore();
    });
  }

  @override
  void dispose() {
    _tidy?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    AppChannel.instance.cardPlugged.removeListener(_onCardPlugged);
    _updater.removeListener(_onUpdate);
    super.dispose();
  }

  // Back from Instagram with a round of publishing out: "Did It Post?"
  // Leaving ShotDrop (closed, or just the home screen): thumbnails and downloads go.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) PublishScreen.showIfPending(context);
    if (state == AppLifecycleState.paused) {
      ThumbCache.clear();
      SourcePrefetch.clear();
      clearCacheFiles(keep: _updater.installing).ignore();
    }
  }

  /// Opened by a card being plugged in: show its photos.
  void _onCardPlugged() {
    _go(HomeTab.gallery);
    _scope.card.refresh();
  }

  void _go(HomeTab tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    HomeShell.hidden.value = false;
    setState(() => _tab = tab);
    // The phone's photos are only read once the Phone Gallery is opened, and again each time.
    if (tab == HomeTab.phone) _scope.phone.refresh();
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
        content: Text('ShotDrop ${latest.version} Is Out'),
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
    child: PlayBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: IndexedStack(
          index: _tab.index,
          children: const [CardScreen(), PhoneScreen(), SelectedScreen(), UploadScreen(), SettingsScreen()],
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
                    child: Center(
                      heightFactor: 1,
                      child: _NavBar(tab: _tab, onTap: _go),
                    ),
                  ),
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
      padding: const EdgeInsets.only(bottom: 18),
      // A lion peeking over the bar's top edge, paws on it.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(left: 24, top: -21, child: PeekingLion()),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(34),
              boxShadow: [
                BoxShadow(color: cardLip, offset: const Offset(0, 6)),
                BoxShadow(color: Color(isLight ? 0x1F6A45E8 : 0x80000000), blurRadius: 24, offset: const Offset(0, 12)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(34),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(34),
                    border: Border.all(color: line, width: 2),
                  ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([scope.uploads, scope.updater]),
                    builder: (context, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NavItem(
                          icon: Icons.sd_card_outlined,
                          activeIcon: Icons.sd_card_rounded,
                          label: 'SD Card',
                          color: tangerine,
                          selected: tab == HomeTab.gallery,
                          onTap: () => onTap(HomeTab.gallery),
                        ),
                        _NavItem(
                          icon: Icons.photo_library_outlined,
                          activeIcon: Icons.photo_library_rounded,
                          label: 'Phone',
                          color: sky,
                          selected: tab == HomeTab.phone,
                          onTap: () => onTap(HomeTab.phone),
                        ),
                        _NavItem(
                          icon: Icons.favorite_border_rounded,
                          activeIcon: Icons.favorite_rounded,
                          label: 'Selected',
                          color: accent,
                          count: scope.uploads.selected.length + scope.uploads.copying,
                          selected: tab == HomeTab.selected,
                          onTap: () => onTap(HomeTab.selected),
                        ),
                        _NavItem(
                          icon: Icons.outbox_outlined,
                          activeIcon: Icons.outbox_rounded,
                          label: 'Upload',
                          color: grass,
                          count: scope.uploads.queued.length,
                          selected: tab == HomeTab.upload,
                          onTap: () => onTap(HomeTab.upload),
                        ),
                        _NavItem(
                          icon: Icons.settings_outlined,
                          activeIcon: Icons.settings_rounded,
                          label: 'Settings',
                          color: grape,
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
          const Positioned(left: 24, top: -4, child: LionPaws()),
        ],
      ),
    );
  }
}

/// One tab, in its own colour: just its icon, or, when it's the open one, a
/// bouncy pill with the icon and its name.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.count = 0,
    this.dot = false,
  });

  final IconData icon, activeIcon;
  final String label;
  final Color color;
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
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: selected ? 14 : 12),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
          boxShadow: selected ? [BoxShadow(color: deeper(color, 0.16), offset: const Offset(0, 3.5))] : const [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: count > 0 || dot,
              smallSize: 10,
              label: count > 0 ? Text('$count') : null,
              backgroundColor: selected ? Colors.white : coral,
              textColor: selected ? deeper(color, 0.1) : Colors.white,
              offset: const Offset(8, -6),
              child: AnimatedScale(
                scale: selected ? 1.12 : 1,
                duration: const Duration(milliseconds: 600),
                curve: Curves.elasticOut,
                child: Icon(selected ? activeIcon : icon, color: selected ? onFun(color) : color, size: 25),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutBack,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 7),
                      child: Text(
                        label,
                        style: TextStyle(color: onFun(color), fontWeight: FontWeight.w700, fontSize: 15),
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
