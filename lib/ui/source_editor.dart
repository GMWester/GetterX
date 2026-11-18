import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';

import 'package:getterx_core/models.dart';
import 'package:getterx_core/selector.dart';

import 'common.dart';

/// Paste link -> resolve -> edit options -> save.
Future<void> addSourceFlow(BuildContext context, AppController c) async {
  final ctl = TextEditingController();
  SourceKind? kind;
  final source = await showDialog<TrackedSource>(
    context: context,
    builder: (ctx) {
      var loading = false;
      String? error;
      return StatefulBuilder(
        builder: (ctx, set) {
          Future<void> go() async {
            set(() {
              loading = true;
              error = null;
            });
            try {
              final s = await c.resolveLink(ctl.text, kind: kind);
              if (ctx.mounted) Navigator.pop(ctx, s);
            } catch (e) {
              set(() {
                loading = false;
                error = '$e';
              });
            }
          }

          return AlertDialog(
            title: const Text('Track something'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Link or id',
                      hintText: 'github.com/owner/repo · modrinth.com/mod/… · curseforge.com/… · author.itch.io/game · gitlab.com/… · codeberg.org/… · f-droid.org/packages/… · or ANY download page / file URL',
                      hintMaxLines: 3,
                    ),
                    onSubmitted: (_) => go(),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<SourceKind?>(
                    initialValue: kind,
                    decoration: const InputDecoration(
                      labelText: 'Source type',
                      helperText: 'Auto-detect works for most links. Pick GitLab / Forgejo for self-hosted servers.',
                      helperMaxLines: 2,
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Detect from link')),
                      for (final k in SourceKind.values) DropdownMenuItem(value: k, child: Text(sourceKindLabel(k))),
                    ],
                    onChanged: (v) => kind = v,
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: loading ? null : go,
                child: loading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Next'),
              ),
            ],
          );
        },
      );
    },
  );
  if (source == null || !context.mounted) return;
  final saved = await Navigator.push<TrackedSource>(
    context,
    MaterialPageRoute(builder: (_) => SourceEditor(c, source, isNew: true)),
  );
  if (saved != null) {
    await c.check(saved.id);
  }
}

class SourceEditor extends StatefulWidget {
  final AppController c;
  final TrackedSource initial;
  final bool isNew;
  const SourceEditor(this.c, this.initial, {super.key, this.isNew = false});
  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<SourceEditor> {
  late final TrackedSource s = widget.initial.copy();
  late final name = TextEditingController(text: s.name);
  late final dir = TextEditingController(text: s.downloadDir);
  late final include = TextEditingController(text: s.includeFilesRegex);
  late final exclude = TextEditingController(text: s.excludeFilesRegex);
  late final versionRe = TextEditingController(text: s.versionRegex);
  late final linkRe = TextEditingController(text: s.linkRegex);
  late final versionExtract = TextEditingController(text: s.versionExtractRegex);
  late final customType = TextEditingController();

  List<String> get commonTypes => s.isMod
      ? const ['jar', 'zip', 'mrpack']
      : const ['exe', 'msi', 'zip', 'apk', 'dmg', 'pkg', 'appimage', 'deb', 'rpm', 'tar.gz', 'ipa', 'jar'];
  late final games = TextEditingController(text: s.gameVersions.join(', '));
  late final customLoader = TextEditingController();
  late final keepCount = TextEditingController(text: s.keepCount == 0 ? '' : '${s.keepCount}');
  late final gvLimit = TextEditingController(text: s.gameVersionLimit == 0 ? '' : '${s.gameVersionLimit}');

  static const knownLoaders = ['fabric', 'forge', 'neoforge', 'quilt'];

  List<TrackMode> get modes => [
    TrackMode.latest,
    TrackMode.newReleases,
    if (s.kind != SourceKind.itchio) TrackMode.allReleases,
    if (s.isMod) TrackMode.latestPerLoaderAndGameVersion,
  ];

  String? _regexError(String v) {
    if (v.trim().isEmpty) return null;
    try {
      RegExp(v);
      return null;
    } catch (_) {
      return 'Invalid regular expression';
    }
  }

  bool _apply() {
    if ([include, exclude, versionRe, linkRe, versionExtract].any((c) => _regexError(c.text) != null)) {
      return false;
    }
    s
      ..name = name.text.trim().isEmpty ? s.name : name.text.trim()
      ..downloadDir = dir.text.trim()
      ..includeFilesRegex = include.text.trim()
      ..excludeFilesRegex = exclude.text.trim()
      ..versionRegex = versionRe.text.trim()
      ..linkRegex = linkRe.text.trim()
      ..versionExtractRegex = versionExtract.text.trim()
      ..gameVersions = games.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
      ..keepCount = int.tryParse(keepCount.text) ?? 0
      ..gameVersionLimit = int.tryParse(gvLimit.text) ?? 0;
    return true;
  }

  Future<void> _save() async {
    if (!_apply()) return;
    await widget.c.saveSource(s);
    if (mounted) Navigator.pop(context, s);
  }

  Future<void> _preview() async {
    if (!_apply()) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Preview'),
        content: SizedBox(
          width: 560,
          child: FutureBuilder<SyncPlan>(
            future: widget.c.engine.preview(s),
            builder: (ctx, snap) {
              if (snap.hasError) return Text('${snap.error}');
              if (!snap.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
              final plan = snap.data!;
              if (plan.isEmpty) return const Text('Nothing to do — up to date.');
              return ListView(
                shrinkWrap: true,
                children: [
                  for (final d in plan.downloads)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.download, color: Colors.green),
                      title: Text('${d.release.version}${d.folder.isEmpty ? '' : '  →  ${d.folder}'}'),
                      subtitle: Text(d.files.map((f) => f.name).join('\n')),
                    ),
                  for (final d in plan.delete)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.delete_outline, color: Colors.red),
                      title: Text('Remove ${d.version}'),
                    ),
                  for (final d in plan.archive)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text('Keep ${d.version} as old version'),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  /// Shows the files of the newest release so the user can tick exactly
  /// which ones to keep downloading (e.g. only the .exe).
  Future<void> _pickFiles() async {
    _apply();
    final probe = s.copy()
      ..includeFilesRegex = ''
      ..excludeFilesRegex = ''
      ..fileTypes = []
      ..onlyPlatformFiles = false
      ..primaryFileOnly = false;
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => _FilePickerDialog(future: widget.c.engine.fetchReleases(probe), preselect: s.includeFilesRegex),
    );
    if (chosen == null) return;
    setState(() {
      include.text = chosen.isEmpty ? '' : patternForFiles(chosen);
      if (chosen.isNotEmpty) {
        s.onlyPlatformFiles = false;
        s.fileTypes = [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMod = s.isMod;
    final defaultFolder = widget.c.engine.folderFor(TrackedSource(id: '', kind: s.kind, ref: '', name: name.text));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Add ${sourceKindLabel(s.kind)} source' : 'Edit ${s.name}'),
        actions: [
          TextButton.icon(
            onPressed: _preview,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Preview'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save')),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              ListTile(leading: Icon(kindIcon(s.kind)), title: Text('${sourceKindLabel(s.kind)}: ${s.ref}')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SectionTitle('Download folder'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: dir,
                        decoration: InputDecoration(
                          labelText: 'Folder for this source',
                          hintText: defaultFolder,
                          helperText: 'Empty = default ($defaultFolder)',
                          helperMaxLines: 2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Browse',
                      onPressed: () async {
                        final d = await pickFolder(context, initial: dir.text.isEmpty ? null : dir.text);
                        if (d != null) setState(() => dir.text = d);
                      },
                      icon: const Icon(Icons.folder_open),
                    ),
                  ],
                ),
              ),
              const SectionTitle('What to download'),
              RadioGroup<TrackMode>(
                groupValue: s.mode,
                onChanged: (v) => setState(() => s.mode = v!),
                child: Column(
                  children: [
                    for (final m in modes)
                      RadioListTile<TrackMode>(
                        value: m,
                        title: Text(trackModeLabel(m)),
                        subtitle: Text(switch (m) {
                          TrackMode.latest => 'Keeps one up-to-date copy, like Obtainium.',
                          TrackMode.newReleases => 'Each new release goes into its own folder.',
                          TrackMode.allReleases => 'Downloads the complete history once, then every new release.',
                          TrackMode.latestPerLoaderAndGameVersion => 'e.g. Fabric + Forge + NeoForge builds for 26.3, 26.2, … — older builds for the same version are ignored.',
                        }),
                      ),
                  ],
                ),
              ),
              const SectionTitle('Release channels'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final ch in ReleaseChannel.values)
                      if (!(s.kind == SourceKind.github && ch == ReleaseChannel.alpha) && s.kind != SourceKind.itchio)
                        FilterChip(
                          label: Text(
                            s.kind == SourceKind.github && ch == ReleaseChannel.beta ? 'pre-release' : ch.name,
                          ),
                          selected: s.channels.contains(ch),
                          onSelected: (v) => setState(() => v ? s.channels.add(ch) : s.channels.remove(ch)),
                        ),
                  ],
                ),
              ),
              SwitchListTile(
                value: s.preferStable,
                onChanged: (v) => setState(() => s.preferStable = v),
                title: const Text('Prefer stable'),
                subtitle: const Text('Use a beta/alpha only when no stable build exists'),
              ),
              if (isMod) ...[
                const SectionTitle('Mod loaders (none selected = all)'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final l in {...knownLoaders, ...s.loaders})
                        FilterChip(
                          label: Text(l),
                          selected: s.loaders.contains(l),
                          onSelected: (v) => setState(() => v ? s.loaders.add(l) : s.loaders.remove(l)),
                        ),
                      SizedBox(
                        width: 160,
                        child: TextField(
                          controller: customLoader,
                          decoration: const InputDecoration(isDense: true, hintText: '+ other loader'),
                          onSubmitted: (v) => setState(() {
                            if (v.trim().isNotEmpty) s.loaders.add(v.trim().toLowerCase());
                            customLoader.clear();
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionTitle('Game versions'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      TextField(
                        controller: games,
                        decoration: const InputDecoration(
                          labelText: 'Only these versions (comma separated, empty = all)',
                          hintText: '26.3, 26.2, 1.21.11',
                        ),
                      ),
                      TextField(
                        controller: gvLimit,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Only the newest N game versions (empty = all)'),
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  value: s.groupMinorVersions,
                  onChanged: (v) => setState(() => s.groupMinorVersions = v),
                  title: const Text('Group minor versions'),
                  subtitle: const Text('Treat 1.21.1 … 1.21.11 as one "1.21" (keeps only the newest of the group)'),
                ),
                SwitchListTile(
                  value: s.includeSnapshots,
                  onChanged: (v) => setState(() => s.includeSnapshots = v),
                  title: const Text('Include snapshot / pre-release game versions'),
                ),
                SwitchListTile(
                  value: s.primaryFileOnly,
                  onChanged: (v) => setState(() => s.primaryFileOnly = v),
                  title: const Text('Only the main file'),
                  subtitle: const Text('Skip sources / dev / api jars'),
                ),
              ],
              const SectionTitle('Old versions'),
              SwitchListTile(
                value: s.keepOld,
                onChanged: s.mode == TrackMode.allReleases ? null : (v) => setState(() => s.keepOld = v),
                title: const Text('Keep old versions'),
                subtitle: Text(
                  s.mode == TrackMode.allReleases
                      ? 'Full archive always keeps everything'
                      : 'Off = delete the previous version once the new one is downloaded',
                ),
              ),
              if (s.keepOld && s.mode != TrackMode.allReleases)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: keepCount,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Keep at most N versions (empty = unlimited)'),
                  ),
                ),
              if (s.kind == SourceKind.web) ...[
                const SectionTitle('Website'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      TextField(
                        controller: linkRe,
                        decoration: InputDecoration(
                          labelText: 'Only links matching (regex, optional)',
                          hintText: r'e.g. /download/.*\.exe',
                          helperText: 'Empty = every link on the page that points to a file (.exe, .apk, .zip, .jar …)',
                          helperMaxLines: 2,
                          errorText: _regexError(linkRe.text),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      TextField(
                        controller: versionExtract,
                        decoration: InputDecoration(
                          labelText: 'Version from link (regex with one group, optional)',
                          hintText: r'e.g. tool-(\d+\.\d+\.\d+)',
                          helperText: 'Empty = first number like 1.2.3 in the file name. A direct file URL is tracked by its server date/size.',
                          helperMaxLines: 2,
                          errorText: _regexError(versionExtract.text),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ],
                  ),
                ),
              ],
              const SectionTitle('Files'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.checklist),
                      label: const Text('Pick files from the latest release…'),
                    ),
                    const SizedBox(height: 8),
                    Text('File types (none selected = all)', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final t in {...commonTypes, ...s.fileTypes})
                          FilterChip(
                            label: Text('.$t'),
                            selected: s.fileTypes.contains(t),
                            onSelected: (v) => setState(() => v ? s.fileTypes.add(t) : s.fileTypes.remove(t)),
                          ),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: customType,
                            decoration: const InputDecoration(isDense: true, hintText: '+ other type'),
                            onSubmitted: (v) => setState(() {
                              final t = v.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');
                              if (t.isNotEmpty && !s.fileTypes.contains(t)) s.fileTypes.add(t);
                              customType.clear();
                            }),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!isMod)
                SwitchListTile(
                  value: s.onlyPlatformFiles,
                  onChanged: (v) => setState(() => s.onlyPlatformFiles = v),
                  title: const Text('Only files for this device'),
                  subtitle: Text(
                    'Picks the right file for ${widget.c.engine.platform.os} ${widget.c.engine.platform.arch} (APK split, .exe, .dmg, AppImage …)',
                  ),
                ),
              if (s.kind == SourceKind.github || s.kind == SourceKind.gitlab || s.kind == SourceKind.forgejo) ...[
                SwitchListTile(
                  value: s.includeSourceArchives,
                  onChanged: (v) => setState(() => s.includeSourceArchives = v),
                  title: const Text('Also download source code (.zip)'),
                ),
                if (s.kind == SourceKind.github)
                  SwitchListTile(
                    value: s.tagsFallback,
                    onChanged: (v) => setState(() => s.tagsFallback = v),
                    title: const Text('Use tags if the repo has no releases'),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    TextField(
                      controller: include,
                      decoration: InputDecoration(
                        labelText: 'Only file names matching (regex)',
                        errorText: _regexError(include.text),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: exclude,
                      decoration: InputDecoration(
                        labelText: 'Skip file names matching (regex)',
                        errorText: _regexError(exclude.text),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: versionRe,
                      decoration: InputDecoration(
                        labelText: 'Only versions / tags matching (regex)',
                        hintText: r'e.g. ^v2\.  or  MC26',
                        errorText: _regexError(versionRe.text),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android)
                SwitchListTile(
                  value: s.autoInstall,
                  onChanged: s.mode == TrackMode.latest ? (v) => setState(() => s.autoInstall = v) : null,
                  title: const Text('Open the installer for new APKs'),
                  subtitle: const Text('Latest-only mode'),
                ),
              SwitchListTile(
                value: s.enabled,
                onChanged: (v) => setState(() => s.enabled = v),
                title: const Text('Include in automatic checks'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilePickerDialog extends StatefulWidget {
  final Future<List<RemoteRelease>> future;
  final String preselect;
  const _FilePickerDialog({required this.future, required this.preselect});
  @override
  State<_FilePickerDialog> createState() => _FilePickerDialogState();
}

class _FilePickerDialogState extends State<_FilePickerDialog> {
  final selected = <String>{};
  bool _init = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Which files?'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<List<RemoteRelease>>(
          future: widget.future,
          builder: (ctx, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            final rels = [...snap.data!]..sort(compareNewest);
            if (rels.isEmpty) return const Text('No releases found.');
            final latest = rels.first;
            final names = latest.files.map((f) => f.name).toList();
            if (!_init) {
              _init = true;
              if (widget.preselect.isNotEmpty) {
                try {
                  final re = RegExp(widget.preselect, caseSensitive: false);
                  selected.addAll(names.where(re.hasMatch));
                } catch (_) {}
              }
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Latest: ${latest.version}. Your choice is remembered for future releases '
                  '(version numbers in the names are matched automatically). Select nothing for all files.',
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final n in names)
                        CheckboxListTile(
                          dense: true,
                          value: selected.contains(n),
                          onChanged: (v) => setState(() => v! ? selected.add(n) : selected.remove(n)),
                          title: Text(n),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, selected), child: const Text('Use selection')),
      ],
    );
  }
}
