import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_channel.dart';
import '../theme.dart';
import '../update.dart';
import '../widgets.dart';

// --- Update ----------------------------------------------------------------------------

/// The update sheet: this version, the newest one and what's in it, and one
/// button that downloads it and opens Android's installer.
Future<void> showUpdateSheet(BuildContext context) {
  final updater = AppScope.of(context).updater;
  if (!updater.checking) updater.check();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _UpdateSheet(updater: updater),
  );
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.updater});
  final Updater updater;

  Future<void> _install(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await updater.install() == InstallOutcome.needsPermission) {
        messenger.showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 6),
            content: Text('Turn on "Allow from this source" for ShotDrop, come back, and tap Update again.'),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t update: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updater,
    builder: (context, _) {
      final latest = updater.latest;
      final progress = updater.progress;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                latest != null ? 'ShotDrop ${latest.version} is out' : 'Update app',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                updater.current.isEmpty ? '' : 'This phone has ${updater.current}',
                style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              if (updater.checking && latest == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
                )
              else if (latest == null)
                _Message(
                  icon: updater.error != null ? Icons.cloud_off_rounded : Icons.verified_rounded,
                  text: updater.error != null
                      ? 'Couldn\'t check for updates. Is the phone online?'
                      : 'You have the newest version.',
                )
              else ...[
                if (latest.notes.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: surfaceHigh, borderRadius: BorderRadius.circular(14)),
                      child: SingleChildScrollView(
                        child: Text(
                          latest.notes.replaceAll('**', ''),
                          style: const TextStyle(fontSize: 13, height: 1.45),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (progress != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: progress, minHeight: 6),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Downloading… ${(progress * 100).round()}% of ${(latest.apkSize / 1e6).toStringAsFixed(0)} MB',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: () => _install(context),
                    icon: const Icon(Icons.system_update_rounded),
                    label: Text('Update to ${latest.version}'),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Android asks you to confirm the install. Your Upload folder and settings stay as they are.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
              if (latest == null && !updater.checking)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: updater.check,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check again'),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: surfaceHigh, borderRadius: BorderRadius.circular(14)),
    child: Row(
      children: [
        Icon(icon, color: accent),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700))),
      ],
    ),
  );
}

// --- Caption auto-paste ------------------------------------------------------------------

/// How to switch on "ShotDrop caption paste": Android only lets the user do
/// it, in Accessibility settings (and, for an app not from the Play Store,
/// after "Allow restricted settings" in its App info).
class CaptionHelperScreen extends StatefulWidget {
  const CaptionHelperScreen({super.key});

  @override
  State<CaptionHelperScreen> createState() => _CaptionHelperScreenState();
}

class _CaptionHelperScreenState extends State<CaptionHelperScreen> with WidgetsBindingObserver {
  bool? _on;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Settings: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final on = await AppChannel.instance.captionHelperOn().catchError((Object _) => false);
    if (mounted) setState(() => _on = on);
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    return Scaffold(
      appBar: AppBar(title: const Text('Caption auto-paste')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: on == true ? positive.withValues(alpha: 0.12) : surfaceHigh,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: on == true ? positive : line),
            ),
            child: Row(
              children: [
                Icon(
                  on == true ? Icons.check_circle_rounded : Icons.content_paste_go_rounded,
                  color: on == true ? positive : accent,
                  size: 30,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    on == null
                        ? 'Checking…'
                        : on
                        ? 'On. When ShotDrop opens a new Instagram post, your caption is typed in for you.'
                        : 'Off. Switch it on once and ShotDrop types your caption into Instagram by itself.',
                    style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text('WHY A SETTING', style: sectionLabel),
          const SizedBox(height: 8),
          const Text(
            'Instagram throws away captions that other apps send. The only way in is an Accessibility helper, '
            'which Android lets only you switch on. ShotDrop\'s helper looks at Instagram only, and only fills '
            'the caption box right after ShotDrop opens a new post.',
            style: TextStyle(color: muted, height: 1.45),
          ),
          const SizedBox(height: 22),
          const Text('SWITCH IT ON', style: sectionLabel),
          const SizedBox(height: 10),
          const _Step(
            n: 1,
            text:
                'Tap "Open Accessibility" below. Find "ShotDrop caption paste" (under Installed apps or Downloaded apps) '
                'and switch it on, then tap Allow.',
          ),
          const _Step(
            n: 2,
            text:
                'If the switch is greyed out ("Restricted setting"): tap "Open App info", tap ⋮ at the top right, '
                'tap "Allow restricted settings", confirm, then do step 1 again.',
          ),
          const _Step(n: 3, text: 'Come back here: this page turns green when it\'s on.'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: AppChannel.instance.openAccessibility,
            icon: const Icon(Icons.accessibility_new_rounded),
            label: const Text('Open Accessibility'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: AppChannel.instance.openAppInfo,
            icon: const Icon(Icons.info_outline_rounded),
            label: const Text('Open App info'),
          ),
          const SizedBox(height: 18),
          const Text(
            'With it off, ShotDrop still copies the caption: long-press the caption box in Instagram and tap Paste.',
            style: TextStyle(fontSize: 12, color: muted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
          child: Text('$n', style: const TextStyle(color: onAccent, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
      ],
    ),
  );
}

/// Copies [text] for pasting, with a short note. Used when the helper is off.
Future<void> copyCaption(ScaffoldMessengerState messenger, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(
    const SnackBar(
      duration: Duration(seconds: 4),
      content: Text('Caption copied. In Instagram, long-press the caption box and tap Paste.'),
    ),
  );
}
