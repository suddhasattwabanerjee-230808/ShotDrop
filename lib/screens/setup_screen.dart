import 'package:flutter/material.dart';

import '../share_channel.dart';
import '../theme.dart';
import '../theme_switch.dart';
import '../widgets.dart';
import 'home_shell.dart';

/// Instagram & Facebook: shown once on first launch, and from the Upload folder.
///
/// Instagram has no way for another app to sign in to a personal account, so
/// "connecting" here means: the Instagram app is on the phone, ShotDrop knows
/// the username to show, and Instagram's own Accounts Center is set to share
/// posts and stories on to Facebook.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.firstRun = false});
  final bool firstRun;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  late final _social = AppScope.of(context).social;
  late final _handle = TextEditingController(text: _social.handle);
  bool? _instagramInstalled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkApps();
    // Shown once: however it's left (Continue, Skip, or back), the app opens on the card next time.
    if (widget.firstRun) _social.save(setupSeen: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // However the screen is left, keep the username that was typed.
    if (_handle.text.trim() != _social.handle) _social.save(handle: _handle.text);
    _handle.dispose();
    super.dispose();
  }

  // Back from installing Instagram or from Accounts Center: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkApps();
  }

  Future<void> _checkApps() async {
    try {
      final apps = await ShareChannel.instance.installedApps();
      if (mounted) setState(() => _instagramInstalled = apps.instagram);
    } catch (_) {
      if (mounted) setState(() => _instagramInstalled = false);
    }
  }

  Future<void> _finish() async {
    await _social.save(handle: _handle.text, setupSeen: true);
    if (!mounted) return;
    if (widget.firstRun) {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const HomeShell()));
    } else {
      Navigator.of(context).pop();
    }
  }

  void _install(String pkg) => ShareChannel.instance.openUrl('https://play.google.com/store/apps/details?id=$pkg');

  @override
  Widget build(BuildContext context) {
    return PlayBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.firstRun ? 'Welcome To ShotDrop' : 'Instagram & Facebook'),
          automaticallyImplyLeading: !widget.firstRun,
          actions: [
            if (widget.firstRun)
              TextButton(
                onPressed: _finish,
                child: Text('Skip', style: TextStyle(color: muted)),
              ),
            const ThemeToggle(),
          ],
        ),
        body: ListenableBuilder(
          listenable: _social,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              const _Hero(),
              const SizedBox(height: 20),
              Text('INSTAGRAM', style: sectionLabel),
              const SizedBox(height: 8),
              _Card(
                children: [
                  _AppRow(
                    name: 'Instagram App',
                    installed: _instagramInstalled,
                    onInstall: () => _install('com.instagram.android'),
                  ),
                  const Divider(height: 24),
                  const Text('Your Username', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Shown when you publish, so you know which account Instagram will post to. '
                    'Instagram posts to whichever account is open in the app.',
                    style: TextStyle(fontSize: 13, color: muted, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _handle,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      prefixIcon: Padding(
                        padding: const EdgeInsets.only(left: 16, right: 4),
                        child: Text(
                          '@',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: muted),
                        ),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      hintText: 'yourname',
                    ),
                    onSubmitted: (v) => _social.save(handle: v),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('FACEBOOK', style: sectionLabel),
              const SizedBox(height: 8),
              _Card(
                children: [
                  const Text(
                    'Post To Facebook Automatically',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Instagram can copy your posts and stories to Facebook. Configure this in Instagram\'s Accounts Center:',
                    style: TextStyle(fontSize: 13, color: muted, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  const _Step(n: 1, text: 'In Instagram, open your profile → the three-line menu → Accounts Center.'),
                  const _Step(n: 2, text: 'Tap Connected experiences → Sharing across profiles.'),
                  const _Step(
                    n: 3,
                    text: 'Share from your Instagram to your Facebook profile, and turn on posts and stories.',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => ShareChannel.instance.openUrl(
                      'https://accountscenter.instagram.com/',
                      app: SocialApp.instagram,
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open Accounts Center'),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(onPressed: _finish, child: Text(widget.firstRun ? 'Continue' : 'Done')),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isLight ? const [Color(0xFFFFE1EE), Color(0xFFFFF1D6)] : const [Color(0xFF4A2163), Color(0xFF2E1F5C)],
      ),
      border: Border.all(color: accent.withValues(alpha: 0.35), width: 2),
      boxShadow: [BoxShadow(color: cardLip, offset: const Offset(0, 5))],
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Flow(),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Card → Edit → Instagram', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'Instagram doesn\'t let other apps sign in to personal accounts, so ShotDrop does everything up to the '
                'last tap: it opens Instagram with your edited photos loaded, and you tap Share.',
                style: TextStyle(fontSize: 13, color: ink.withValues(alpha: 0.8), height: 1.45),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Flow extends StatelessWidget {
  const _Flow();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (i, icon) in const [
        Icons.sd_card_rounded,
        Icons.auto_fix_high_rounded,
        Icons.send_rounded,
      ].indexed) ...[
        if (i > 0) Container(width: 3, height: 10, color: muted.withValues(alpha: 0.4)),
        Builder(
          builder: (context) {
            final c = [tangerine, grape, accent][i];
            return Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: deeper(c, 0.16), offset: const Offset(0, 3))],
              ),
              child: Icon(icon, size: 21, color: Colors.white),
            );
          },
        ),
      ],
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  // A Material, not a coloured box, so the switch row's ink shows on it.
  @override
  Widget build(BuildContext context) => Material(
    color: surface,
    shape: ChunkyBorder(
      borderRadius: BorderRadius.circular(26),
      side: BorderSide(color: line, width: 2),
      depth: 5,
      lip: cardLip,
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.name, required this.installed, required this.onInstall, this.subtitle});
  final String name;
  final String? subtitle;
  final bool? installed; // null while checking
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ),
      switch (installed) {
        null => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        true => PhotoBadge(label: 'INSTALLED', icon: Icons.check_rounded, color: grass, fg: const Color(0xFF06210F)),
        false => TextButton(onPressed: onInstall, child: const Text('Install')),
      },
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: rainbow[n % rainbow.length], shape: BoxShape.circle),
          child: Text(
            '$n',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: onFun(rainbow[n % rainbow.length])),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
      ],
    ),
  );
}
