import 'package:flutter/material.dart';

import '../app_channel.dart';
import '../stores.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'grid_screen.dart';

/// The Phone Gallery: every photo in the phone's own gallery, once Android
/// has let ShotDrop see them. Lists them again whenever the app comes back
/// to the front (new photos taken meanwhile).
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> with WidgetsBindingObserver {
  late final _phone = AppScope.of(context).phone;

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
    if (state == AppLifecycleState.resumed && _phone.state != PhoneState.unknown) _phone.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _phone,
    builder: (context, _) {
      if (_phone.state == PhoneState.ready) return const GridScreen(gallery: Gallery.phone);
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Phone Gallery'),
          actions: const [ThemeToggle()],
          bottom: const GalleryToggle(current: Gallery.phone),
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(key: ValueKey(_phone.state), child: _body()),
        ),
      );
    },
  );

  Widget _body() => switch (_phone.state) {
    PhoneState.unknown || PhoneState.loading => const StatePanel(
      icon: Icons.photo_library_outlined,
      iconWidget: SizedBox(
        width: 96,
        height: 96,
        child: CircularProgressIndicator(strokeWidth: 7, strokeCap: StrokeCap.round),
      ),
      title: 'Opening The Phone\'s Photos…',
      body: 'Every photo in the phone\'s gallery, newest first.',
    ),
    PhoneState.noAccess => StatePanel(
      icon: Icons.photo_library_outlined,
      title: 'See The Phone\'s Photos',
      body: 'ShotDrop can edit and post the photos in your phone\'s gallery too. Android asks once before it can see them.',
      actions: [
        FilledButton.icon(
          onPressed: _phone.requestAccess,
          icon: const Icon(Icons.lock_open_rounded),
          label: const Text('Allow Access'),
        ),
      ],
    ),
    PhoneState.blocked => StatePanel(
      icon: Icons.no_photography_outlined,
      title: 'Photos Are Switched Off',
      body: 'Android won\'t ask again. In App Info, open Permissions > Photos and videos, and choose Allow all.',
      actions: [
        FilledButton.icon(
          onPressed: () => AppChannel.instance.openAppInfo(),
          icon: const Icon(Icons.settings_rounded),
          label: const Text('Open App Info'),
        ),
        TextButton(onPressed: _phone.refresh, child: const Text('Check Again')),
      ],
    ),
    PhoneState.error => StatePanel(
      icon: Icons.error_outline_rounded,
      title: 'Couldn\'t Read The Photos',
      body: _phone.error ?? 'Something went wrong.',
      actions: [FilledButton(onPressed: _phone.refresh, child: const Text('Try Again'))],
    ),
    PhoneState.ready => const SizedBox.shrink(),
  };
}
