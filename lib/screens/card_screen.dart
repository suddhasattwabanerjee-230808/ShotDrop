import 'package:flutter/material.dart';

import '../stores.dart';
import '../theme.dart';
import '../widgets.dart';
import 'grid_screen.dart';
import 'upload_screen.dart';

/// The home screen: the card's photos once it's plugged in, otherwise what to
/// do to get there. Rechecks the card whenever the app comes back to the front.
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
          appBar: AppBar(title: const Text('ShotDrop'), actions: const [UploadFolderButton(), SizedBox(width: 8)]),
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
      case CardState.noFolder:
        return StatePanel(
          icon: Icons.sd_card_outlined,
          title: 'Plug in your camera card',
          body:
              'Put the D5600\'s SD card in a card reader and connect it to the phone with the OTG adapter. '
              'Then pick the card\'s DCIM folder, just once. ShotDrop remembers it after that.',
          actions: [
            FilledButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Choose the card\'s DCIM folder'),
            ),
          ],
        );
      case CardState.waiting:
        return StatePanel(
          icon: Icons.usb_rounded,
          iconWidget: const _PulsingIcon(icon: Icons.usb_rounded),
          title: 'Waiting for the card',
          body: 'Connect the card reader. The photos will open by themselves as soon as the card shows up.',
          actions: [
            OutlinedButton.icon(
              onPressed: card.refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Check again'),
            ),
            TextButton(onPressed: () => _pick(context), child: const Text('Use a different card')),
          ],
        );
      case CardState.loading:
        return const StatePanel(
          icon: Icons.sd_card_outlined,
          iconWidget: SizedBox(width: 96, height: 96, child: CircularProgressIndicator(strokeWidth: 3)),
          title: 'Reading the card…',
          body: 'Finding every photo in the DCIM folder.',
        );
      case CardState.error:
        return StatePanel(
          icon: Icons.error_outline_rounded,
          title: 'Couldn\'t read the card',
          body: card.error ?? 'Something went wrong.',
          actions: [
            FilledButton(onPressed: card.refresh, child: const Text('Try again')),
            TextButton(onPressed: () => _pick(context), child: const Text('Choose the folder again')),
          ],
        );
      case CardState.ready:
        return const SizedBox.shrink();
    }
  }

  Future<void> _pick(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppScope.of(context).card.pickFolder();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t open that folder: $e')));
    }
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

/// App-bar button to the Upload folder, with how many photos are waiting.
class UploadFolderButton extends StatelessWidget {
  const UploadFolderButton({super.key});

  @override
  Widget build(BuildContext context) {
    final uploads = AppScope.of(context).uploads;
    return ListenableBuilder(
      listenable: uploads,
      builder: (context, _) {
        final n = uploads.queued.length;
        return IconButton(
          tooltip: 'Upload folder',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UploadScreen())),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n'),
            backgroundColor: accent,
            textColor: onAccent,
            child: const Icon(Icons.outbox_rounded),
          ),
        );
      },
    );
  }
}
