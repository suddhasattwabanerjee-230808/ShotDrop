import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_channel.dart';
import '../edit/post_shape.dart';
import '../publish.dart';
import '../storage.dart';
import '../stores.dart';
import '../theme.dart';
import '../widgets.dart';
import 'app_screens.dart';
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
  int? _keptBytes, _postedBytes, _cacheBytes, _freeBytes; // its photos; posted copies; thumbnails and downloads; the phone's free space

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
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
    int? kept, posted, cache;
    if (!mounted) return;
    final uploads = AppScope.of(context).uploads;
    final free = await AppChannel.instance.freeSpace().catchError((Object _) => -1);
    try {
      kept = await _size(await getApplicationSupportDirectory());
      cache = await _size(await getTemporaryDirectory());
      posted = 0;
      for (final i in uploads.items.where((i) => i.published)) {
        for (final path in [i.sourcePath, ?i.exportPath]) {
          posted = posted! + await File(path).length().catchError((Object _) => 0);
        }
      }
    } catch (_) {
      // Sizes are a nicety; leave them blank if storage can't be read.
    }
    if (mounted) {
      setState(() {
        _captionOn = on;
        _version = v;
        _keptBytes = kept == null || posted == null ? kept : kept - posted;
        _postedBytes = posted;
        _cacheBytes = cache;
        _freeBytes = free < 0 ? null : free;
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

  static String _mb(int? bytes) => bytes == null
      ? '…'
      : bytes >= 1e9
      ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
      : '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB';

  Future<void> _tidyNow() async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final freed = await tidyStorage(scope.uploads, scope.settings);
    await _refresh();
    messenger.showSnackBar(
      SnackBar(content: Text(freed < 100000 ? 'Already Tidy: Nothing To Clear' : 'Freed ${_mb(freed)}')),
    );
  }

  Future<void> _clearCache() async {
    final messenger = ScaffoldMessenger.of(context);
    await clearCacheFiles(keep: AppScope.of(context).updater.installing);
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
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete Copies')),
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
                  leading: const InstagramLogo(),
                  title: scope.social.handle.isEmpty ? 'Instagram & Facebook' : '@${scope.social.handle}',
                  subtitle: scope.social.instagramSharesToFacebook
                      ? 'Posts Also Go To Facebook, Through Instagram'
                      : 'Username, Apps, Sharing To Facebook',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetupScreen())),
                ),
                _Row(
                  icon: Icons.content_paste_go_rounded,
                  title: 'Caption Auto-Paste',
                  subtitle: _captionOn == null
                      ? '…'
                      : _captionOn!
                      ? 'On: ShotDrop Types The Caption Into Instagram'
                      : 'Off: The Caption Is Copied For You To Paste',
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
                  title: 'Card',
                  subtitle: scope.card.state == CardState.ready
                      ? 'Plugged In · ${scope.card.shots.length} Shots'
                      : 'Not Plugged In',
                ),
                _Row(icon: Icons.refresh_rounded, title: 'Rescan The Card', onTap: scope.card.refresh),
                _Switch(
                  icon: Icons.usb_rounded,
                  title: 'Open When A Card Is Plugged In',
                  subtitle: 'Android May Ask Once Whether ShotDrop Should Always Open For The Card Reader',
                  value: settings.openOnCard,
                  onChanged: (v) => settings.set(openOnCard: v),
                ),
              ],
            ),
            _Section(
              title: 'EDITING',
              children: [
                _Switch(
                  icon: Icons.crop_portrait_rounded,
                  title: 'Start Portrait Photos At 4:5',
                  subtitle: 'Instagram\'s tallest post shape; the D5600\'s 2:3 gets cropped otherwise',
                  value: settings.portraitAt45,
                  onChanged: (v) => settings.set(portraitAt45: v),
                ),
                _Choice<int>(
                  icon: Icons.photo_size_select_large_rounded,
                  title: 'Saved Size',
                  value: settings.saveEdge,
                  options: const [(2160, 'Sharpest', '2160 px'), (1080, 'Smaller', '1080 px, Instagram\'s Size')],
                  onChanged: (v) => settings.set(saveEdge: v),
                ),
                _Switch(
                  icon: Icons.photo_album_outlined,
                  title: 'Copy Edits To The Gallery',
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
                  title: 'Publish Starts On',
                  value: settings.publishMode,
                  options: [for (final m in PublishMode.values) (m.name, m.label, null)],
                  onChanged: (v) => settings.set(publishMode: v),
                ),
                _Choice<String>(
                  icon: Icons.aspect_ratio_rounded,
                  title: 'Photos That Don\'t Fit A Post',
                  value: settings.postFit,
                  options: [for (final f in PostFit.values) (f.name, f.label, '${f.detail}. Posts go from 4:5 to 1.91:1.')],
                  onChanged: (v) => settings.set(postFit: v),
                ),
              ],
            ),
            _Section(
              title: 'STORAGE',
              children: [
                _Row(
                  icon: Icons.inventory_2_outlined,
                  title: 'Selected And Upload Folder',
                  subtitle: '${_mb(_keptBytes)} · Your Picks And Edits',
                ),
                _Row(
                  icon: Icons.storage_rounded,
                  title: 'Phone Storage',
                  subtitle: _freeBytes == null
                      ? '…'
                      : '${_mb(_freeBytes)} Free${_freeBytes! < lowSpaceBytes ? ' · Low, So ShotDrop Tidies Harder' : ''}',
                ),
                _Switch(
                  icon: Icons.auto_delete_outlined,
                  title: 'Tidy Up Automatically',
                  subtitle:
                      'At Launch And After Publishing: Unused Copies, Old Thumbnails, Installed Updates And Old Error Notes',
                  value: settings.autoTidy,
                  onChanged: (v) => settings.set(autoTidy: v),
                ),
                _Choice<int>(
                  icon: Icons.history_rounded,
                  title: 'Keep Copies Of Posted Photos',
                  value: settings.keepPostedDays,
                  options: const [
                    (1, '1 Day', null),
                    (7, '1 Week', null),
                    (30, '1 Month', null),
                    (0, 'Until I Clear Them', null),
                  ],
                  onChanged: (v) => settings.set(keepPostedDays: v),
                ),
                _Row(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Tidy Up Now',
                  subtitle: 'Clears what ShotDrop no longer needs. Selected and the Upload folder stay.',
                  onTap: _tidyNow,
                ),
                _Row(
                  icon: Icons.delete_sweep_outlined,
                  title: 'Free Up Space From Posted Photos',
                  subtitle: '${_mb(_postedBytes)} · All Posted Copies, Now',
                  onTap: _clearPosted,
                ),
                _Row(
                  icon: Icons.layers_clear_outlined,
                  title: 'Clear Thumbnails And Downloads',
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
                  title: scope.updater.available ? 'Update To ${scope.updater.latest!.version}' : 'Check For Updates',
                  subtitle: _version.isEmpty ? null : 'This Is ShotDrop $_version',
                  trailing: scope.updater.available ? const _Dot() : null,
                  onTap: () => showUpdateSheet(context),
                ),
                _Switch(
                  icon: Icons.update_rounded,
                  title: 'Check For Updates At Launch',
                  value: settings.checkUpdates,
                  onChanged: (v) => settings.set(checkUpdates: v),
                ),
                _Row(
                  icon: Icons.info_outline_rounded,
                  title: 'About ShotDrop',
                  subtitle: 'D5600 Card → Edit → Instagram',
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
  const _Row({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap, this.leading});
  final IconData icon;
  final Widget? leading; // in place of the icon (the Instagram logo)
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: leading ?? Icon(icon, color: accent),
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
