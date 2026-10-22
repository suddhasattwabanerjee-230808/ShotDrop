import 'package:flutter/material.dart';

import '../stores.dart';
import '../theme.dart';
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
          appBar: AppBar(
            title: const Text('SD Card Gallery'),
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
        return StatePanel(
          icon: Icons.sd_card_outlined,
          iconWidget: const _PulsingIcon(icon: Icons.sd_card_outlined),
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
          iconWidget: SizedBox(width: 96, height: 96, child: CircularProgressIndicator(strokeWidth: 3)),
          title: 'Reading The Card…',
          body: 'Finding every photo in the DCIM folder.',
        );
      case CardState.error:
        return StatePanel(
          icon: Icons.error_outline_rounded,
          title: 'Couldn\'t Read The Card',
          body: card.error ?? 'Something went wrong.',
          actions: [
            FilledButton(onPressed: card.refresh, child: const Text('Try Again')),
          ],
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
          for (final phase in [0.0, 0.5])
            Builder(
              builder: (context) {
                final t = (_c.value + phase) % 1;
                return Container(
                  width: 96 + 44 * t,
                  height: 96 + 44 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: accent.withValues(alpha: (1 - t) * 0.5), width: 2),
                  ),
                );
              },
            ),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: surface,
              shape: BoxShape.circle,
              border: Border.all(color: line),
            ),
            child: Icon(widget.icon, size: 42, color: accent),
          ),
        ],
      ),
    ),
  );
}
