import 'package:flutter/material.dart';

import '../share_channel.dart';
import '../theme.dart';
import '../widgets.dart';
import 'card_screen.dart';

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
  ({bool instagram, bool facebook})? _apps;

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
      if (mounted) setState(() => _apps = apps);
    } catch (_) {
      if (mounted) setState(() => _apps = (instagram: false, facebook: false));
    }
  }

  Future<void> _finish() async {
    await _social.save(handle: _handle.text, setupSeen: true);
    if (!mounted) return;
    if (widget.firstRun) {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const CardScreen()));
    } else {
      Navigator.of(context).pop();
    }
  }

  void _install(String pkg) => ShareChannel.instance.openUrl('https://play.google.com/store/apps/details?id=$pkg');

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.firstRun ? 'Welcome to ShotDrop' : 'Instagram & Facebook'),
        automaticallyImplyLeading: !widget.firstRun,
        actions: [
          if (widget.firstRun)
            TextButton(
              onPressed: _finish,
              child: const Text('Skip', style: TextStyle(color: muted)),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _social,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            const _Hero(),
            const SizedBox(height: 20),
            const Text('INSTAGRAM', style: sectionLabel),
            const SizedBox(height: 8),
            _Card(
              children: [
                _AppRow(
                  name: 'Instagram app',
                  installed: apps?.instagram,
                  onInstall: () => _install('com.instagram.android'),
                ),
                const Divider(height: 24),
                const Text('Your username', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Shown when you publish, so you know which account Instagram will post to. '
                  'Instagram posts to whichever account is open in the app.',
                  style: TextStyle(fontSize: 13, color: muted, height: 1.4),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _handle,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(left: 16, right: 4),
                      child: Text(
                        '@',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: muted),
                      ),
                    ),
                    prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
                    hintText: 'yourname',
                  ),
                  onSubmitted: (v) => _social.save(handle: v),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('FACEBOOK', style: sectionLabel),
            const SizedBox(height: 8),
            _Card(
              children: [
                const Text(
                  'Post to Facebook automatically',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Instagram can copy every post and story to your Facebook profile by itself. Turn it on once:',
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
                  onPressed: () =>
                      ShareChannel.instance.openUrl('https://accountscenter.instagram.com/', app: SocialApp.instagram),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open Accounts Center'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _social.instagramSharesToFacebook,
                  onChanged: (v) => _social.save(instagramSharesToFacebook: v),
                  title: const Text("It's on", style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text(
                    'Otherwise ShotDrop can open Facebook for each post too.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                const Divider(height: 24),
                _AppRow(
                  name: 'Facebook app',
                  subtitle: 'Only needed if Instagram doesn\'t share for you',
                  installed: apps?.facebook,
                  onInstall: () => _install('com.facebook.katana'),
                ),
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
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3B2A12), Color(0xFF16161B)],
      ),
      border: Border.all(color: line),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Flow(),
        SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Card → edit → Instagram', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              SizedBox(height: 6),
              Text(
                'Instagram doesn\'t let other apps sign in to personal accounts, so ShotDrop does everything up to the '
                'last tap: it opens Instagram with your edited photos loaded, and you tap Share.',
                style: TextStyle(fontSize: 13, color: Color(0xCCFFFFFF), height: 1.45),
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
        if (i > 0) Container(width: 2, height: 10, color: accent.withValues(alpha: 0.5)),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: i == 2 ? accent : surfaceHigh, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 19, color: i == 2 ? onAccent : accent),
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
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: line),
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
            if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ),
      switch (installed) {
        null => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        true => const PhotoBadge(label: 'INSTALLED', icon: Icons.check_rounded, color: positive, fg: Color(0xFF06210F)),
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
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: surfaceHigh, shape: BoxShape.circle),
          child: Text(
            '$n',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: accent),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
      ],
    ),
  );
}
