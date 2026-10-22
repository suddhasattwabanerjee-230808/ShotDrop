import 'package:flutter/material.dart';

import '../stores.dart';
import '../theme.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'grid_screen.dart';

/// The SD Card Gallery: the card's photos while it's plugged in, otherwise
/// what to do to get there. Rechecks the card whenever the app comes back to
/// the front.
class CardScreen extends StatefulWidget {
  const CardScreen({super.key});

  @override
  State<CardScreen> createState() => _CardScreenState();
}

class _CardScreenState extends State<CardScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) AppScope.of(context).card.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.card,
      builder: (context, _) {
        final card = scope.card;
        if (card.state == CardState.ready) return const GridScreen();
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('SD Card Gallery'),
            actions: const [ThemeToggle()],
            bottom: const GalleryToggle(current: Gallery.card),
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(key: ValueKey(card.state), child: _body(context, card)),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, CardStore card) {
    switch (card.state) {
      // No card in (unplugged, or never picked): the same first page either way.
      case CardState.noFolder:
      case CardState.waiting:
        return const StatePanel(
          icon: Icons.sd_card_outlined,
          iconWidget: _PulsingIcon(icon: Icons.sd_card_outlined),
          title: 'Plug In Your Camera Card',
          body:
              'Put the D5600\'s SD card in a card reader and connect it to the phone with the OTG adapter. '
              'ShotDrop notices it by itself.',
        );
      case CardState.newCard:
        return StatePanel(
          icon: Icons.sd_card_rounded,
          iconWidget: const _PulsingIcon(icon: Icons.sd_card_rounded),
          title: 'Card Found',
          body:
              'Android asks once per card before an app can read it. Tap below, then "Use this folder" and "Allow": '
              'the card\'s DCIM folder is already open. Next time this card opens by itself.',
          actions: [
            FilledButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.photo_library_rounded),
              label: Text('Open ${card.cardName ?? 'the card'}'),
            ),
          ],
        );
      case CardState.loading:
        return const StatePanel(
          icon: Icons.sd_card_outlined,
          iconWidget: SizedBox(
            width: 96,
            height: 96,
            child: CircularProgressIndicator(strokeWidth: 7, strokeCap: StrokeCap.round),
          ),
          title: 'Reading The Card…',
          body: 'Finding every photo in the DCIM folder.',
        );
      case CardState.error:
        return StatePanel(
          icon: Icons.error_outline_rounded,
          title: 'Couldn\'t Read The Card',
          body: card.error ?? 'Something went wrong.',
          actions: [FilledButton(onPressed: card.refresh, child: const Text('Try Again'))],
        );
      case CardState.ready:
        return const SizedBox.shrink();
    }
  }

  Future<void> _pick(BuildContext context) => pickCardFolder(context);
}

/// Opens Android's one-time access screen on the plugged-in card's DCIM
/// folder, then shows the card's photos.
Future<void> pickCardFolder(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await AppScope.of(context).card.pickFolder();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t Open That Folder: $e')));
  }
}

class _PulsingIcon extends StatefulWidget {
  const _PulsingIcon({required this.icon});
  final IconData icon;

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 140,
    height: 140,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Stack(
        alignment: Alignment.center,
        children: [
          for (final (phase, colour) in [(0.0, accent), (0.33, tangerine), (0.66, sky)])
            Builder(
              builder: (context) {
                final t = (_c.value + phase) % 1;
                return Container(
                  width: 96 + 44 * t,
                  height: 96 + 44 * t,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular((96 + 44 * t) * 0.36),
                    border: Border.all(color: colour.withValues(alpha: (1 - t) * 0.7), width: 3),
                  ),
                );
              },
            ),
          Transform.scale(
            // A little heartbeat with each ring.
            scale: 1 + 0.05 * Curves.easeOutBack.transform(1 - ((_c.value * 3) % 1)),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [tangerine, accent],
                ),
                borderRadius: BorderRadius.circular(96 * 0.36),
                border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 3),
                boxShadow: [BoxShadow(color: deeper(accent, 0.2), offset: const Offset(0, 6))],
              ),
              child: Icon(widget.icon, size: 44, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}
