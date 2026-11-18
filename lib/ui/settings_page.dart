import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:getterx_core/backup.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_installer/getterx_installer.dart';
import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import '../app/notifications.dart';
import '../app/self_update.dart';
import '../app/theme.dart';
import 'accounts_page.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  final AppController c;
  const SettingsPage(this.c, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get c => widget.c;
  late final dir = TextEditingController(text: c.settings.downloadDir);
  late final cfBase = TextEditingController(text: c.settings.curseforgeBaseUrl);
  late final ghClient = TextEditingController(text: c.settings.githubClientId);
  bool checking = false;

  static const intervals = {
    0: 'Only manually',
    30: 'Every 30 minutes',
    60: 'Every hour',
    180: 'Every 3 hours',
    360: 'Every 6 hours',
    720: 'Every 12 hours',
    1440: 'Daily',
  };

  Future<void> _save() async {
    final s = c.settings
      ..downloadDir = dir.text.trim()
      ..githubClientId = ghClient.text.trim();
    final base = cfBase.text.trim();
    if (base.isNotEmpty && !base.startsWith('https://')) {
      toast(context, 'The CurseForge API address must start with https://');
      return;
    }
    s.curseforgeBaseUrl = base;
    await c.saveSettings();
    if (mounted) setState(() {});
  }

  Widget _swipePicker(String value, void Function(String) set) => DropdownButton<String>(
    value: value,
    items: const [
      DropdownMenuItem(value: 'none', child: Text('Nothing')),
      DropdownMenuItem(value: 'check', child: Text('Check now')),
      DropdownMenuItem(value: 'install', child: Text('Install / update')),
      DropdownMenuItem(value: 'pin', child: Text('Pin')),
      DropdownMenuItem(value: 'edit', child: Text('Edit')),
      DropdownMenuItem(value: 'open', child: Text('Open folder')),
      DropdownMenuItem(value: 'delete', child: Text('Remove (with undo)')),
    ],
    onChanged: (v) {
      set(v!);
      _save();
    },
  );

  Future<void> _export() async {
    final text = c.exportConfig();
    final dir = Directory(c.engine.downloadRoot);
    final now = DateTime.now();
    final name =
        'GetterX-backup-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.json';
    try {
      await dir.create(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text);
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) toast(context, 'Saved to ${f.path} (also copied to the clipboard)');
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) toast(context, 'Copied to the clipboard ($e)');
    }
  }

  Future<void> _import() async {
    String? text;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Import from'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'file'), child: const Text('A file')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'paste'), child: const Text('Pasted text')),
        ],
      ),
    );
    if (choice == 'file') {
      final f = await FilePicker.pickFile(dialogTitle: 'Choose a backup');
      if (f == null) return;
      text = await f.xFile.readAsString();
    } else if (choice == 'paste') {
      final ctl = TextEditingController();
      if (!mounted) return;
      text = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Paste backup or links'),
          content: TextField(controller: ctl, maxLines: 8, minLines: 4),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Next')),
          ],
        ),
      );
    }
    if (text == null || text.trim().isEmpty || !mounted) return;
    List<TrackedSource> found;
    try {
      found = parseBackup(text).sources;
    } catch (_) {
      // Not a GetterX backup: treat it as links (Obtainium/ObtainX exports work too).
      found = [];
      final links = linksFromText(text);
      for (final l in links) {
        try {
          found.add(await c.resolveLink(l));
        } catch (_) {}
      }
    }
    if (!mounted) return;
    if (found.isEmpty) {
      toast(context, 'Nothing to import found');
      return;
    }
    final picked = {for (final s in found) s.id: true};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Import ${picked.values.where((v) => v).length} of ${found.length}'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final s in found)
                  CheckboxListTile(
                    value: picked[s.id],
                    onChanged: (v) => set(() => picked[s.id] = v!),
                    title: Text(s.name),
                    subtitle: Text('${sourceKindLabel(s.kind)} · ${s.ref}'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = await c.importSources(found.where((s) => picked[s.id] == true).toList());
    if (mounted) toast(context, 'Imported $n (already tracked ones were skipped)');
  }

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final kind = detectInstallKind();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              const SectionTitle('Downloads'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: dir,
                        decoration: InputDecoration(
                          labelText: 'Default download folder',
                          hintText: c.paths.defaultDownloadRoot,
                          helperText: 'Each source gets a sub-folder here unless it has its own folder.',
                        ),
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () async {
                        final d = await pickFolder(
                          context,
                          initial: dir.text.isEmpty ? c.paths.defaultDownloadRoot : dir.text,
                        );
                        if (d != null) {
                          dir.text = d;
                          await _save();
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                    ),
                  ],
                ),
              ),
              const SectionTitle('Automatic checks'),
              ListTile(
                title: const Text('Check interval'),
                trailing: DropdownButton<int>(
                  value: intervals.containsKey(s.checkIntervalMinutes) ? s.checkIntervalMinutes : 360,
                  items: [for (final e in intervals.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) async {
                    s.checkIntervalMinutes = v!;
                    await _save();
                    // Re-register only if background checks are on (new interval) or must be turned off.
                    if (c.backgroundEnabled) {
                      final err = await c.setBackground(v != 0);
                      if (mounted && err != null) toast(this.context, 'Background checks: $err');
                    }
                  },
                ),
              ),
              SwitchListTile(
                value: c.backgroundEnabled,
                onChanged: s.checkIntervalMinutes == 0
                    ? null
                    : (v) async {
                        final mobile = Platform.isAndroid || Platform.isIOS;
                        if (v && !mobile) {
                          final ok = await confirm(
                            context,
                            'Check while GetterX is closed?',
                            'GetterX will add a scheduled task (${Platform.isWindows
                                    ? 'Task Scheduler'
                                    : Platform.isMacOS
                                    ? 'launchd'
                                    : 'systemd timer'}) '
                                'that starts it without a window every ${s.checkIntervalMinutes} minutes.\n\n'
                                'Some antivirus programs (e.g. Microsoft Defender) may warn about this, because unsigned '
                                'programs that schedule themselves look like malware to their heuristics. '
                                'If that happens, turn this off again or allow GetterX in your antivirus.',
                            ok: 'Turn on',
                          );
                          if (!ok) return;
                        }
                        final err = await c.setBackground(v);
                        if (mounted && err != null) toast(this.context, 'Background checks: $err');
                        setState(() {});
                      },
                title: const Text('Also check while GetterX is closed'),
                subtitle: Text(
                  Platform.isAndroid || Platform.isIOS
                      ? 'Uses the system scheduler (timing decided by the OS, at least 15 min).'
                      : 'Off by default. Adds a scheduled task that runs GetterX without a window. '
                            'While GetterX is open it checks on schedule anyway.',
                ),
              ),
              const SectionTitle('Accounts'),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Sign in to GitHub, itch.io, Modrinth, CurseForge'),
                subtitle: const Text('Optional — for private repos, purchased games and higher limits'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountsPage(c))),
              ),
              const SectionTitle('GetterX updates'),
              ListTile(
                title: Text('Version ${c.currentVersion.isEmpty ? '?' : c.currentVersion}'),
                subtitle: Text('${installKindLabel(kind)}${c.paths.portable ? ' · portable' : ''}'),
                trailing: checking
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : FilledButton.tonal(
                        onPressed: () async {
                          setState(() => checking = true);
                          try {
                            final u = await c.checkForAppUpdate();
                            if (!context.mounted) return;
                            if (u == null) {
                              toast(context, 'GetterX is up to date');
                            } else if (await confirm(
                              context,
                              'Update to ${u.version}?',
                              u.asset == null
                                  ? 'Opens the download page.'
                                  : 'GetterX will download the update, verify it and restart.',
                              ok: 'Update',
                            )) {
                              await c.installAppUpdate();
                            }
                          } catch (e) {
                            if (context.mounted) toast(context, 'Update check failed: $e');
                          } finally {
                            if (mounted) setState(() => checking = false);
                          }
                        },
                        child: const Text('Check for update'),
                      ),
              ),
              SwitchListTile(
                value: s.checkAppUpdates,
                onChanged: (v) {
                  s.checkAppUpdates = v;
                  _save();
                },
                title: const Text('Tell me when a new GetterX version is out'),
              ),
              SwitchListTile(
                value: s.autoUpdateApp,
                onChanged: kind == InstallKind.ios
                    ? null
                    : (v) {
                        s.autoUpdateApp = v;
                        _save();
                      },
                title: const Text('Update GetterX automatically'),
                subtitle: Text(
                  kind == InstallKind.android
                      ? 'Android always asks you to confirm the install.'
                      : kind == InstallKind.ios
                      ? 'Not possible on iOS — update via your sideloading tool.'
                      : 'Downloads, verifies (SHA-256) and installs on start-up.',
                ),
              ),
              const SectionTitle('Appearance'),
              ListTile(
                title: const Text('Theme'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'system', label: Text('Auto')),
                      ButtonSegment(value: 'light', label: Text('Light')),
                      ButtonSegment(value: 'dark', label: Text('Dark')),
                      ButtonSegment(value: 'oled', label: Text('OLED black')),
                    ],
                    selected: {s.themeMode},
                    onSelectionChanged: (v) {
                      s.themeMode = v.first;
                      _save();
                    },
                  ),
                ),
              ),
              SwitchListTile(
                value: s.tintedBackgrounds,
                onChanged: (v) {
                  s.tintedBackgrounds = v;
                  _save();
                },
                title: const Text('Tint backgrounds with the accent colour'),
                subtitle: const Text('Off = neutral grey backgrounds'),
              ),
              SwitchListTile(
                value: s.perAppColors,
                onChanged: (v) {
                  s.perAppColors = v;
                  _save();
                },
                title: const Text('Colour each page from its icon'),
              ),
              ListTile(
                title: const Text('Accent colour'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        avatar: const Icon(Icons.palette_outlined, size: 18),
                        label: const Text('System'),
                        selected: s.accentColor == 'system',
                        onSelected: (_) {
                          s.accentColor = 'system';
                          _save();
                        },
                      ),
                      for (final e in accentPresets.entries)
                        Tooltip(
                          message: e.value,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              s.accentColor = e.key;
                              _save();
                            },
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: parseAccent(e.key),
                              child: s.accentColor == e.key
                                  ? const Icon(Icons.check, size: 18, color: Colors.black)
                                  : null,
                            ),
                          ),
                        ),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          decoration: const InputDecoration(isDense: true, hintText: '#hex', prefixText: '#'),
                          onSubmitted: (v) {
                            final hex = v.replaceAll('#', '').trim();
                            if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
                              s.accentColor = hex.toLowerCase();
                              _save();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SectionTitle('List'),
              ListTile(title: const Text('Swipe right'), trailing: _swipePicker(s.swipeRight, (v) => s.swipeRight = v)),
              ListTile(title: const Text('Swipe left'), trailing: _swipePicker(s.swipeLeft, (v) => s.swipeLeft = v)),
              const SectionTitle('Notifications'),
              SwitchListTile(
                value: s.notifyUpdates,
                onChanged: (v) async {
                  s.notifyUpdates = v;
                  if (v) await Notifier.requestPermission();
                  _save();
                },
                title: const Text('Notify about new versions'),
                subtitle: const Text('Installs and problems are always notified'),
              ),
              if (Platform.isAndroid) ...[
                const SectionTitle('Installing apps'),
                FutureBuilder<bool>(
                  future: GetterxInstaller.canInstall(),
                  builder: (context, snap) => ListTile(
                    leading: Icon(snap.data == true ? Icons.verified_outlined : Icons.warning_amber),
                    title: Text(snap.data == true ? 'GetterX may install apps' : 'Allow GetterX to install apps'),
                    subtitle: const Text(
                      'Needed for automatic updates. On Android 12+ updates of apps GetterX installed happen without a tap.',
                    ),
                    trailing: snap.data == true
                        ? null
                        : FilledButton.tonal(
                            onPressed: GetterxInstaller.openInstallPermissionSettings,
                            child: const Text('Allow'),
                          ),
                  ),
                ),
              ],
              const SectionTitle('Backup'),
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Export tracked sources and settings'),
                subtitle: const Text('Logins are never included'),
                onTap: _export,
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Import…'),
                subtitle: const Text('GetterX backup, Obtainium/ObtainX export, or a list of links'),
                onTap: _import,
              ),
              ExpansionTile(
                title: const Text('Advanced'),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        TextField(
                          controller: cfBase,
                          decoration: const InputDecoration(
                            labelText: 'CurseForge API address',
                            hintText: 'empty = official API (with key) or public mirror (without)',
                            helperText: 'Your CurseForge key is only ever sent to api.curseforge.com.',
                          ),
                          onSubmitted: (_) => _save(),
                        ),
                        TextField(
                          controller: ghClient,
                          decoration: const InputDecoration(
                            labelText: 'GitHub OAuth app client id (for "Sign in with GitHub")',
                            helperText:
                                'Create an OAuth app with "Device flow" enabled on github.com/settings/developers',
                            helperMaxLines: 2,
                          ),
                          onSubmitted: (_) => _save(),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ],
              ),
              const SectionTitle('About'),
              ListTile(
                title: const Text('Data folder'),
                subtitle: Text(
                  '${c.paths.dataDir.path}${c.paths.portable ? '\nPortable mode: everything stays next to the program.' : ''}',
                ),
                onTap: Platform.isIOS || Platform.isAndroid ? null : () => openFolder(c.paths.dataDir.path),
              ),
              ListTile(
                title: const Text('Source code & releases'),
                subtitle: const Text('github.com/$selfRepo'),
                onTap: () => openUrl('https://github.com/$selfRepo'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
