import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import '../app/self_update.dart';
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
    final err = await c.saveSettings();
    if (mounted && err != null) toast(context, 'Background checks: $err');
    setState(() {});
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
                  onChanged: (v) {
                    s.checkIntervalMinutes = v!;
                    if (v == 0) s.backgroundChecks = false;
                    _save();
                  },
                ),
              ),
              SwitchListTile(
                value: s.backgroundChecks,
                onChanged: s.checkIntervalMinutes == 0
                    ? null
                    : (v) {
                        s.backgroundChecks = v;
                        _save();
                      },
                title: const Text('Also check while GetterX is closed'),
                subtitle: Text(
                  Platform.isAndroid || Platform.isIOS
                      ? 'Uses the system scheduler (timing decided by the OS, at least 15 min).'
                      : 'Registers a scheduled task that runs GetterX without a window.',
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
