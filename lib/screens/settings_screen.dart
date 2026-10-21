import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_channel.dart';
import '../publish.dart';
import '../theme.dart';
import '../widgets.dart';
import 'app_screens.dart';
import 'card_screen.dart';
import 'home_shell.dart';
import 'setup_screen.dart';

/// Settings: the Instagram side, the card, how edits are saved, how
/// publishing starts, the space ShotDrop uses, and updates.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _captionOn;
  String _version = '';
  int? _keptBytes, _cacheBytes; // photos ShotDrop keeps; thumbnails and downloads

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Accessibility settings: the caption helper may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final on = await AppChannel.instance.captionHelperOn().catchError((Object _) => false);
    final v = await AppChannel.instance.version().then((v) => v.name).catchError((Object _) => '');
    int? kept, cache;
    try {
      kept = await _size(await getApplicationSupportDirectory());
      cache = await _size(await getTemporaryDirectory());
    } catch (_) {
      // Sizes are a nicety; leave them blank if storage can't be read.
    }
    if (mounted) {
      setState(() {
        _captionOn = on;
        _version = v;
        _keptBytes = kept;
        _cacheBytes = cache;
      });
    }
  }

  static Future<int> _size(Directory dir) async {
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length().catchError((Object _) => 0);
      }
    } catch (_) {}
    return total;
  }

  static String _mb(int? bytes) => bytes == null ? '…' : '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB';

  /// "DCIM on the card (1A2B-3C4D)" from the folder's tree uri.
  static String _folderName(String? uri) {
    if (uri == null) return 'None picked yet';
    final id = Uri.decodeComponent(uri.split('/tree/').last);
    final (volume, path) = switch (id.indexOf(':')) {
      -1 => ('', id),
      final i => (id.substring(0, i), id.substring(i + 1)),
    };
    final where = volume == 'primary' ? 'on the phone' : 'on the card${volume.isEmpty ? '' : ' ($volume)'}';
    return '${path.isEmpty ? 'The whole drive' : path} $where';
  }

  Future<void> _clearCache() async {
    final messenger = ScaffoldMessenger.of(context);
    final dir = await getTemporaryDirectory();
    for (final name in ['thumbs', 'updates']) {
      await Directory('${dir.path}/$name').delete(recursive: true).catchError((Object _) => dir);
    }
    ThumbCache.clear();
    await _refresh();
    messenger.showSnackBar(const SnackBar(content: Text('Thumbnails cleared. They\'re made again as you scroll.')));
  }

  Future<void> _clearPosted() async {
    final uploads = AppScope.of(context).uploads;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Free up space from posted photos?'),
        content: const Text(
          'ShotDrop deletes its own copies of photos you\'ve posted. They stay on Instagram, on the card, and in '
          'Pictures/ShotDrop/Published, and the Gallery still marks them POSTED.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete copies')),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await uploads.clearPosted();
    await _refresh();
    messenger.showSnackBar(SnackBar(content: Text('Freed ${_mb(freed)}')));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, scope.social, scope.card, scope.updater]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, navBarClearance + 24),
          children: [
            _Section(
              title: 'INSTAGRAM',
              children: [
                _Row(
                  icon: Icons.alternate_email_rounded,
                  title: scope.social.handle.isEmpty ? 'Instagram & Facebook' : '@${scope.social.handle}',
                  subtitle: scope.social.instagramSharesToFacebook
                      ? 'Posts also go to Facebook, through Instagram'
                      : 'Username, apps, sharing to Facebook',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetupScreen())),
                ),
                _Row(
                  icon: Icons.content_paste_go_rounded,
                  title: 'Caption auto-paste',
                  subtitle: _captionOn == null
                      ? '…'
                      : _captionOn!
                      ? 'On: ShotDrop types the caption into Instagram'
                      : 'Off: the caption is copied for you to paste',
                  trailing: _Pill(on: _captionOn == true),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CaptionHelperScreen()));
                    _refresh();
                  },
                ),
              ],
            ),
            _Section(
              title: 'CAMERA CARD',
              children: [
                _Row(
                  icon: Icons.sd_card_outlined,
                  title: 'Folder',
                  subtitle: _folderName(scope.card.folder),
                ),
                _Row(
                  icon: Icons.folder_open_rounded,
                  title: 'Choose another folder',
                  onTap: () async {
                    await pickCardFolder(context);
                    if (context.mounted && scope.card.shots.isNotEmpty) HomeShell.go(context, HomeTab.gallery);
                  },
                ),
                _Row(icon: Icons.refresh_rounded, title: 'Rescan the card', onTap: scope.card.refresh),
              ],
            ),
            _Section(
              title: 'EDITING',
              children: [
                _Switch(
                  icon: Icons.crop_portrait_rounded,
                  title: 'Start portrait photos at 4:5',
                  subtitle: 'Instagram\'s tallest post shape; the D5600\'s 2:3 gets cropped otherwise',
                  value: settings.portraitAt45,
                  onChanged: (v) => settings.set(portraitAt45: v),
                ),
                _Choice<int>(
                  icon: Icons.photo_size_select_large_rounded,
                  title: 'Saved size',
                  value: settings.saveEdge,
                  options: const [(2160, 'Sharpest', '2160 px'), (1080, 'Smaller', '1080 px, Instagram\'s size')],
                  onChanged: (v) => settings.set(saveEdge: v),
                ),
                _Switch(
                  icon: Icons.photo_album_outlined,
                  title: 'Copy edits to the gallery',
                  subtitle: 'In Pictures/ShotDrop, so other apps can use them',
                  value: settings.galleryCopy,
                  onChanged: (v) => settings.set(galleryCopy: v),
                ),
              ],
            ),
            _Section(
              title: 'PUBLISHING',
              children: [
                _Choice<String>(
                  icon: Icons.send_rounded,
                  title: 'Publish starts on',
                  value: settings.publishMode,
                  options: [for (final m in PublishMode.values) (m.name, m.label, null)],
                  onChanged: (v) => settings.set(publishMode: v),
                ),
              ],
            ),
            _Section(
              title: 'STORAGE',
              children: [
                _Row(
                  icon: Icons.inventory_2_outlined,
                  title: 'Photos ShotDrop keeps',
                  subtitle: '${_mb(_keptBytes)} · Selected, Upload folder and posted copies',
                ),
                _Row(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Free up space from posted photos',
                  onTap: _clearPosted,
                ),
                _Row(
                  icon: Icons.layers_clear_outlined,
                  title: 'Clear thumbnails and downloads',
                  subtitle: _mb(_cacheBytes),
                  onTap: _clearCache,
                ),
              ],
            ),
            _Section(
              title: 'APP',
              children: [
                _Row(
                  icon: Icons.system_update_rounded,
                  title: scope.updater.available ? 'Update to ${scope.updater.latest!.version}' : 'Check for updates',
                  subtitle: _version.isEmpty ? null : 'This is ShotDrop $_version',
                  trailing: scope.updater.available ? const _Dot() : null,
                  onTap: () => showUpdateSheet(context),
                ),
                _Switch(
                  icon: Icons.update_rounded,
                  title: 'Check for updates at launch',
                  value: settings.checkUpdates,
                  onChanged: (v) => settings.set(checkUpdates: v),
                ),
                _Row(
                  icon: Icons.info_outline_rounded,
                  title: 'About ShotDrop',
                  subtitle: 'D5600 card → edit → Instagram',
                  onTap: () => showLicensePage(context: context, applicationName: 'ShotDrop', applicationVersion: _version),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.only(left: 6, bottom: 8), child: Text(title, style: sectionLabel)),
        Material(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, c) in children.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 56, color: line),
                c,
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: accent),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: muted, fontSize: 12)),
    trailing: trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right_rounded, color: muted)),
    onTap: onTap,
  );
}

class _Switch extends StatelessWidget {
  const _Switch({required this.icon, required this.title, required this.value, required this.onChanged, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: Icon(icon, color: accent),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: muted, fontSize: 12)),
    value: value,
    onChanged: onChanged,
  );
}

/// A setting with a few named values, as chips under its title.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final T value;
  final List<(T, String, String?)> options; // value, label, detail
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final detail = options.where((o) => o.$1 == value).firstOrNull?.$3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: accent)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                if (detail != null) Text(detail, style: const TextStyle(color: muted, fontSize: 12)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (v, label, _) in options)
                      ChoiceChip(
                        label: Text(label),
                        selected: v == value,
                        showCheckmark: false,
                        selectedColor: accent,
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: v == value ? onAccent : ink,
                        ),
                        onSelected: (_) => onChanged(v),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: on ? positive.withValues(alpha: 0.15) : surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: on ? positive : line),
    ),
    child: Text(
      on ? 'ON' : 'OFF',
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: on ? positive : muted),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) =>
      Container(width: 10, height: 10, decoration: const BoxDecoration(color: accent, shape: BoxShape.circle));
}
