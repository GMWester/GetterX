import 'dart:io';

import 'package:getterx_core/discovery.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/selector.dart';
import 'package:getterx_installer/getterx_installer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../app/desktop_installer.dart';
import '../app/installs.dart';
import '../app/theme.dart';
import 'common.dart';
import 'source_editor.dart';
import 'source_icon.dart';

class SourceDetailPage extends StatefulWidget {
  final AppController c;
  final String id;

  /// Shown inside the two-pane layout (no back button).
  final bool embedded;
  const SourceDetailPage(this.c, this.id, {super.key, this.embedded = false});
  @override
  State<SourceDetailPage> createState() => _SourceDetailPageState();
}

class _SourceDetailPageState extends State<SourceDetailPage> {
  AppController get c => widget.c;
  ThemeData? _iconTheme;
  String? _themedFor;

  void _loadTheme(TrackedSource s, ThemeData base) {
    final key = '${s.iconUrl}|${base.colorScheme.brightness}|${base.scaffoldBackgroundColor}';
    if (!c.settings.perAppColors || s.iconUrl == null || _themedFor == key) return;
    _themedFor = key;
    themeFromIcon(s.iconUrl!, base, tinted: c.settings.tintedBackgrounds).then((t) {
      if (mounted) setState(() => _iconTheme = t);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.byId(widget.id);
        if (s == null) return const Scaffold(body: Center(child: Text('Removed')));
        final base = Theme.of(context);
        _loadTheme(s, base);
        final page = _page(context, s);
        return c.settings.perAppColors && _iconTheme != null ? Theme(data: _iconTheme!, child: page) : page;
      },
    );
  }

  Widget _page(BuildContext context, TrackedSource s) {
    final running = c.engine.isRunning(s.id);
    final installing = c.installing.contains(s.id);
    final prog = c.progress[s.id];
    final folder = c.engine.folderFor(s);
    final status = c.statusOf(s);
    final inst = s.packageId == null ? null : c.installed[s.packageId];
    final active = s.downloads.where((d) => !isArchivedSlot(d.slot)).toList()
      ..sort((a, b) => (b.publishedAt ?? b.downloadedAt).compareTo(a.publishedAt ?? a.downloadedAt));
    final old = s.downloads.where((d) => isArchivedSlot(d.slot)).toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(s.name),
        actions: [
          IconButton(
            tooltip: s.pinned ? 'Unpin' : 'Pin to top',
            icon: Icon(s.pinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () => c.togglePin(s),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SourceEditor(c, s))),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _menu(context, s, v),
            itemBuilder: (_) => [
              if (s.pageUrl != null) const PopupMenuItem(value: 'page', child: Text('Open web page')),
              const PopupMenuItem(value: 'switch', child: Text('Switch to another source…')),
              const PopupMenuItem(value: 'remove', child: Text('Remove (keep files)')),
              const PopupMenuItem(value: 'removeFiles', child: Text('Remove and delete files')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListTile(
            leading: SourceIcon(s, size: 56),
            title: Text('${sourceKindLabel(s.kind)} · ${s.ref}'),
            subtitle: Text(
              '${trackModeLabel(s.mode)}\nChecked ${ago(s.lastChecked)}'
              '${s.latestVersionSeen == null ? '' : ' · latest ${s.latestVersionSeen}'}'
              '${s.categories.isEmpty ? '' : '\nFolders: ${s.categories.join(', ')}'}',
            ),
            isThreeLine: true,
          ),
          if (status != AppStatus.notAnApp)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: Icon(status == AppStatus.updateAvailable ? Icons.system_update : Icons.phone_android),
                title: Text(appStatusLabel(status)),
                subtitle: Text(
                  [
                    'Installed: ${inst?.versionName ?? '—'}',
                    'Downloaded: ${s.apkVersionName ?? '—'}',
                    if (s.packageId != null) s.packageId!,
                  ].join('\n'),
                ),
                isThreeLine: true,
              ),
            ),
          if (s.installProblem != null || s.lastError != null) _problems(context, s),
          Padding(
            padding: const EdgeInsets.all(16),
            child: running
                ? Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(prog?.message ?? 'Working…'),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(value: prog?.fraction),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => c.cancel(s.id),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ],
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => c.check(s.id),
                        icon: const Icon(Icons.sync),
                        label: Text(s.mode == TrackMode.trackOnly ? 'Check now' : 'Check & download'),
                      ),
                      if (_hasInstallable(s))
                        FilledButton.tonalIcon(
                          onPressed: installing
                              ? null
                              : () async {
                                  final o = await c.installLatest(s);
                                  if (context.mounted) toast(context, o?.message ?? 'Nothing to install');
                                },
                          icon: installing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.install_mobile),
                          label: Text(status == AppStatus.updateAvailable ? 'Update' : 'Install'),
                        ),
                      if (Platform.isAndroid && inst != null) ...[
                        OutlinedButton.icon(
                          onPressed: () => GetterxInstaller.launch(s.packageId!),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => GetterxInstaller.appInfo(s.packageId!),
                          icon: const Icon(Icons.info_outline),
                          label: const Text('App info'),
                        ),
                      ],
                      if (s.latestVersionSeen != null &&
                          s.skippedVersion != s.latestVersionSeen &&
                          status != AppStatus.upToDate)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await c.skipVersion(s, s.latestVersionSeen);
                            if (context.mounted) {
                              toast(context, 'Skipping ${s.latestVersionSeen}; the next version will show up again.');
                            }
                          },
                          icon: const Icon(Icons.skip_next),
                          label: Text('Skip ${s.latestVersionSeen}'),
                        ),
                      if (s.skippedVersion != null)
                        TextButton(
                          onPressed: () => c.skipVersion(s, null),
                          child: Text('Stop skipping ${s.skippedVersion}'),
                        ),
                    ],
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder),
            subtitle: Text(s.downloadDir.isEmpty ? 'Default folder' : 'Custom folder'),
            trailing: Platform.isIOS ? null : const Icon(Icons.open_in_new),
            onTap: Platform.isIOS ? null : () => openFolder(folder),
          ),
          _AlsoAvailable(c, s),
          SectionTitle('Downloaded (${active.length})'),
          if (active.isEmpty) const ListTile(title: Text('Nothing downloaded yet')),
          for (final d in active) _RecordTile(d, folder),
          if (old.isNotEmpty) ...[
            SectionTitle('Kept old versions (${old.length})'),
            for (final d in old) _RecordTile(d, folder),
          ],
        ],
      ),
    );
  }

  bool _hasInstallable(TrackedSource s) => s.downloads.any(
    (d) => d.files.any((f) => Platform.isAndroid ? f.toLowerCase().endsWith('.apk') : isInstallable(f)),
  );

  Widget _problems(BuildContext context, TrackedSource s) {
    final cs = Theme.of(context).colorScheme;
    final problem = s.installProblem ?? '';
    return Card(
      color: cs.errorContainer,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'Needs attention',
                  style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              shortError([s.installProblem, s.lastError].whereType<String>().join('\n'), lines: 8),
              style: TextStyle(color: cs.onErrorContainer),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (problem.contains('Allow GetterX to install'))
                  TextButton(
                    onPressed: GetterxInstaller.openInstallPermissionSettings,
                    child: const Text('Open setting'),
                  ),
                if (problem.contains('Signature differs') && s.packageId != null)
                  TextButton(
                    onPressed: () => GetterxInstaller.uninstall(s.packageId!),
                    child: const Text('Uninstall current app'),
                  ),
                if (s.lastError?.contains('rate limit') == true || s.lastError?.contains('HTTP 403') == true)
                  const Text('Tip: sign in to the service in Settings → Accounts for higher limits.'),
                TextButton(
                  onPressed: () async {
                    s.installProblem = null;
                    s.lastError = null;
                    await c.saveSource(s);
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, TrackedSource s, String v) async {
    switch (v) {
      case 'page':
        await openUrl(s.pageUrl!);
      case 'switch':
        final ctl = TextEditingController();
        final link = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Switch source'),
            content: TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New link',
                helperText: 'Settings, folders and downloaded files are kept.',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Switch')),
            ],
          ),
        );
        if (link == null || link.trim().isEmpty) return;
        try {
          await c.switchSource(s, link);
          if (context.mounted) toast(context, 'Now tracking ${sourceKindLabel(s.kind)}');
        } catch (e) {
          if (context.mounted) toast(context, '$e');
        }
      case 'remove':
      case 'removeFiles':
        final del = v == 'removeFiles';
        if (!await confirm(
          context,
          'Remove ${s.name}?',
          del ? 'Stops tracking and DELETES its downloaded files.' : 'Stops tracking. Downloaded files stay on disk.',
          ok: 'Remove',
        )) {
          return;
        }
        if (del) {
          await c.removeSource(s, deleteFiles: true);
        } else {
          await c.removeWithUndo(s);
        }
        if (context.mounted && !widget.embedded) Navigator.pop(context);
    }
  }
}

class _AlsoAvailable extends StatelessWidget {
  final AppController c;
  final TrackedSource s;
  const _AlsoAvailable(this.c, this.s);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Alternative>>(
      future: c.alternatives(s),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ListTile(
            dense: true,
            leading: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('Looking for other sources…'),
          );
        }
        final alts = snap.data ?? const [];
        if (alts.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('Also available on'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in alts)
                    ActionChip(
                      avatar: Icon(kindIcon(a.kind), size: 18),
                      label: Text('${sourceKindLabel(a.kind)}${a.confidence >= 3 ? ' ✓' : ''}'),
                      tooltip: '${a.title} — ${a.reason}',
                      onPressed: () => _actions(context, a),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _actions(BuildContext context, Alternative a) async {
    final tracked = c.sources.any(
      (x) => '${x.kind.name}:${x.ref}'.toLowerCase() == a.link.toLowerCase() || x.pageUrl == a.link,
    );
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(kindIcon(a.kind)),
              title: Text('${a.title} on ${sourceKindLabel(a.kind)}'),
              subtitle: Text('${a.reason}${a.confidence >= 3 ? ' (exact match)' : ''}'),
            ),
            if (!tracked)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Track this one too'),
                subtitle: const Text('Same settings, its own folder'),
                onTap: () => Navigator.pop(ctx, 'track'),
              ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Switch to this source'),
              subtitle: const Text('Keeps settings, folders and downloaded files'),
              onTap: () => Navigator.pop(ctx, 'switch'),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open page'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
          ],
        ),
      ),
    );
    if (v == null || !context.mounted) return;
    try {
      switch (v) {
        case 'track':
          final n = await c.trackAlternative(s, a.link);
          if (context.mounted) toast(context, 'Now also tracking ${n.name}');
          c.check(n.id);
        case 'switch':
          await c.switchSource(s, a.link);
          if (context.mounted) toast(context, 'Switched to ${sourceKindLabel(a.kind)}');
        case 'open':
          final url = a.link.startsWith('https://')
              ? a.link
              : switch (a.kind) {
                  SourceKind.curseforge => 'https://www.curseforge.com/projects/${a.link.split(':').last}',
                  SourceKind.fdroid => 'https://f-droid.org/packages/${a.link.split(':').last}/',
                  SourceKind.izzyondroid => 'https://apt.izzysoft.de/fdroid/index/apk/${a.link.split(':').last}',
                  _ => a.link,
                };
          await openUrl(url);
      }
    } catch (e) {
      if (context.mounted) toast(context, '$e');
    }
  }
}

class _RecordTile extends StatelessWidget {
  final DownloadRecord d;
  final String root;
  const _RecordTile(this.d, this.root);
  @override
  Widget build(BuildContext context) {
    final slot = baseSlot(d.slot);
    final label = slot.startsWith('slot:') ? slot.substring(5).split('|').reversed.join(' · ') : null;
    return ExpansionTile(
      title: Text(label == null ? d.version : '$label  —  ${d.version}'),
      subtitle: Text('Published ${ago(d.publishedAt)} · downloaded ${ago(d.downloadedAt)}'),
      children: [
        for (final f in d.files)
          ListTile(
            dense: true,
            leading: Icon(f.toLowerCase().endsWith('.apk') ? Icons.android : Icons.insert_drive_file_outlined),
            title: Text(p.basename(f)),
            subtitle: Text(p.isWithin(root, f) ? p.relative(f, from: root) : f),
            trailing: File(f).existsSync() ? const Icon(Icons.open_in_new, size: 18) : const Text('missing'),
            onTap: () => OpenFilex.open(f),
          ),
      ],
    );
  }
}
