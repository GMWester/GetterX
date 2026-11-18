import 'dart:io';

import 'package:getterx_core/models.dart';
import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import '../app/installs.dart';
import 'common.dart';
import 'device_import_page.dart';
import 'log_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'source_detail_page.dart';
import 'source_editor.dart';
import 'source_icon.dart';

enum _Filter { all, updates, attention, pinned, notInstalled }

enum _Sort { name, updated, status }

class HomePage extends StatefulWidget {
  final AppController c;
  const HomePage(this.c, {super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppController get c => widget.c;
  final _query = TextEditingController();
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.name;
  String? _category;
  bool _group = false;
  String? _selected; // two-pane selection

  List<TrackedSource> _visible() {
    final q = _query.text.trim().toLowerCase();
    var list = c.sources.where((s) {
      if (q.isNotEmpty && !'${s.name} ${s.ref} ${s.categories.join(' ')}'.toLowerCase().contains(q)) return false;
      if (_category != null && !s.categories.contains(_category)) return false;
      return switch (_filter) {
        _Filter.all => true,
        _Filter.updates => c.hasUpdate(s),
        _Filter.attention => c.needsAttention(s),
        _Filter.pinned => s.pinned,
        _Filter.notInstalled => c.statusOf(s) == AppStatus.notInstalled,
      };
    }).toList();
    int rank(TrackedSource s) => c.needsAttention(s) ? 0 : (s.pinned ? 1 : (c.hasUpdate(s) ? 2 : 3));
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return switch (_sort) {
        _Sort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        _Sort.updated =>
          (b.downloads.isEmpty
                  ? DateTime(0)
                  : b.downloads.map((d) => d.downloadedAt).reduce((x, y) => x.isAfter(y) ? x : y))
              .compareTo(
                a.downloads.isEmpty
                    ? DateTime(0)
                    : a.downloads.map((d) => d.downloadedAt).reduce((x, y) => x.isAfter(y) ? x : y),
              ),
        _Sort.status => c.statusOf(a).index.compareTo(c.statusOf(b).index),
      };
    });
    return list;
  }

  void _open(TrackedSource s, bool wide) {
    if (wide) {
      setState(() => _selected = s.id);
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => SourceDetailPage(c, s.id)));
    }
  }

  Future<bool> _swipe(TrackedSource s, String action) async {
    switch (action) {
      case 'check':
        c.check(s.id);
      case 'pin':
        await c.togglePin(s);
      case 'install':
        final o = await c.installLatest(s);
        if (mounted && o != null) toast(context, '${s.name}: ${o.message}');
      case 'edit':
        await Navigator.push(context, MaterialPageRoute(builder: (_) => SourceEditor(c, s)));
      case 'open':
        await openFolder(c.engine.folderFor(s));
      case 'delete':
        await c.removeWithUndo(s);
        if (!mounted) return false;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Removed ${s.name} (files kept)'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(label: 'Undo', onPressed: () => c.undoRemove()),
            ),
          );
        return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        final visible = _visible();
        final list = _buildList(visible, wide);
        final selected = _selected == null ? null : c.byId(_selected!);
        return Scaffold(
          appBar: AppBar(
            title: const Text('GetterX'),
            actions: [
              IconButton(
                tooltip: 'Search sources',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SearchPage(c))),
                icon: const Icon(Icons.travel_explore),
              ),
              IconButton(
                tooltip: 'Check all now',
                onPressed: c.busy ? null : () => c.checkAll(),
                icon: c.busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  final page = switch (v) {
                    'log' => LogPage(c),
                    'device' => DeviceImportPage(c),
                    _ => SettingsPage(c),
                  };
                  Navigator.push(context, MaterialPageRoute(builder: (_) => page));
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'log',
                    child: ListTile(leading: Icon(Icons.history), title: Text('Activity')),
                  ),
                  if (Platform.isAndroid)
                    const PopupMenuItem(
                      value: 'device',
                      child: ListTile(leading: Icon(Icons.install_mobile), title: Text('Import from device')),
                    ),
                  const PopupMenuItem(
                    value: 'settings',
                    child: ListTile(leading: Icon(Icons.settings), title: Text('Settings')),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => addSourceFlow(context, c),
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
          body: Column(
            children: [
              if (c.availableUpdate != null) _UpdateBanner(c),
              if (c.credentialError != null)
                MaterialBanner(
                  content: Text(c.credentialError!),
                  leading: const Icon(Icons.lock_outline),
                  actions: [
                    TextButton(onPressed: () => setState(() => c.credentialError = null), child: const Text('OK')),
                  ],
                ),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          SizedBox(width: 440, child: list),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: selected == null
                                ? const Center(child: Text('Select something on the left'))
                                : SourceDetailPage(c, selected.id, key: ValueKey(selected.id), embedded: true),
                          ),
                        ],
                      )
                    : list,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList(List<TrackedSource> visible, bool wide) {
    final cats = c.allCategories;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Filter ${c.sources.length} tracked',
              border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_query.clear)),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final f in _Filter.values)
                  if (f != _Filter.notInstalled || Platform.isAndroid)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(switch (f) {
                          _Filter.all => 'All',
                          _Filter.updates => 'Updates (${c.sources.where(c.hasUpdate).length})',
                          _Filter.attention => 'Needs attention (${c.sources.where(c.needsAttention).length})',
                          _Filter.pinned => 'Pinned',
                          _Filter.notInstalled => 'Not installed',
                        }),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                for (final cat in cats)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: const Icon(Icons.folder_outlined, size: 16),
                      label: Text(cat),
                      selected: _category == cat,
                      onSelected: (v) => setState(() => _category = v ? cat : null),
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Sort and group',
                  icon: const Icon(Icons.sort),
                  onSelected: (v) => setState(() {
                    if (v == 'group') {
                      _group = !_group;
                    } else {
                      _sort = _Sort.values.byName(v);
                    }
                  }),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'name',
                      checked: _sort == _Sort.name,
                      child: const Text('Sort by name'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'updated',
                      checked: _sort == _Sort.updated,
                      child: const Text('Recently updated'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'status',
                      checked: _sort == _Sort.status,
                      child: const Text('By status'),
                    ),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(value: 'group', checked: _group, child: const Text('Group by folder')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (c.sources.isEmpty) return Column(children: [Expanded(child: const _Empty())]);
    final rows = <Widget>[];
    if (_group) {
      final groups = <String, List<TrackedSource>>{};
      for (final s in visible) {
        for (final g in s.categories.isEmpty ? ['No folder'] : s.categories) {
          (groups[g] ??= []).add(s);
        }
      }
      for (final e in (groups.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
        rows.add(SectionTitle('${e.key} (${e.value.length})'));
        rows.addAll(e.value.map((s) => _tile(s, wide)));
      }
    } else {
      rows.addAll(visible.map((s) => _tile(s, wide)));
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        header,
        if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Nothing matches')),
          ),
        ...rows,
      ],
    );
  }

  Widget _tile(TrackedSource s, bool wide) {
    final st = c.settings;
    Widget bg(String action, Alignment a) => Container(
      color: action == 'delete'
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.secondaryContainer,
      alignment: a,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(swipeIcon(action)),
    );
    final tile = _SourceTile(c, s, selected: wide && _selected == s.id, onTap: () => _open(s, wide));
    if (st.swipeLeft == 'none' && st.swipeRight == 'none') return tile;
    return Dismissible(
      key: ValueKey('d-${s.id}'),
      direction: st.swipeLeft == 'none'
          ? DismissDirection.startToEnd
          : (st.swipeRight == 'none' ? DismissDirection.endToStart : DismissDirection.horizontal),
      background: bg(st.swipeRight, Alignment.centerLeft),
      secondaryBackground: bg(st.swipeLeft, Alignment.centerRight),
      confirmDismiss: (dir) => _swipe(s, dir == DismissDirection.startToEnd ? st.swipeRight : st.swipeLeft),
      child: tile,
    );
  }
}

IconData swipeIcon(String a) => switch (a) {
  'check' => Icons.sync,
  'pin' => Icons.push_pin_outlined,
  'delete' => Icons.delete_outline,
  'edit' => Icons.tune,
  'open' => Icons.folder_open,
  'install' => Icons.install_mobile,
  _ => Icons.block,
};

class _UpdateBanner extends StatelessWidget {
  final AppController c;
  const _UpdateBanner(this.c);
  @override
  Widget build(BuildContext context) {
    final u = c.availableUpdate!;
    return MaterialBanner(
      leading: const Icon(Icons.system_update),
      content: c.updateProgress != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Downloading GetterX ${u.version}…'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: c.updateProgress),
              ],
            )
          : Text('GetterX ${u.version} is available (you have ${c.currentVersion}).'),
      actions: [
        TextButton(onPressed: () => openUrl(u.release.pageUrl ?? ''), child: const Text('Changes')),
        FilledButton(
          onPressed: c.updateProgress != null
              ? null
              : () async {
                  try {
                    await c.installAppUpdate();
                  } catch (e) {
                    if (context.mounted) toast(context, 'Update failed: $e');
                  }
                },
          child: Text(u.asset == null ? 'Open download page' : 'Update now'),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_for_offline_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('Nothing tracked yet', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Tap Add and paste a link, or use the search button to find mods, modpacks, plugins and repositories.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _SourceTile extends StatelessWidget {
  final AppController c;
  final TrackedSource s;
  final bool selected;
  final VoidCallback onTap;
  const _SourceTile(this.c, this.s, {required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = c.engine.isRunning(s.id);
    final installing = c.installing.contains(s.id);
    final prog = c.progress[s.id];
    final status = c.statusOf(s);
    final installedV = s.packageId == null ? null : c.installed[s.packageId]?.versionName;
    final attention = s.installProblem ?? s.lastError;
    final line2 = [
      sourceKindLabel(s.kind),
      if (s.latestVersionSeen != null) s.latestVersionSeen!,
      if (installedV != null) 'installed $installedV',
      'checked ${ago(s.lastChecked)}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: selected ? cs.secondaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SourceIcon(s),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (s.pinned)
                          const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.push_pin, size: 14)),
                        Flexible(
                          child: Text(
                            s.name,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(decoration: s.enabled ? null : TextDecoration.lineThrough),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      running && prog != null ? prog.message : line2,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (attention != null)
                          _Badge(shortError(attention, lines: 1), cs.errorContainer, cs.onErrorContainer),
                        if (status != AppStatus.notAnApp)
                          _Badge(
                            appStatusLabel(status),
                            status == AppStatus.updateAvailable ? cs.primaryContainer : cs.surfaceContainerHighest,
                            status == AppStatus.updateAvailable ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                          )
                        else if (c.newVersionIds.contains(s.id))
                          _Badge('New version', cs.primaryContainer, cs.onPrimaryContainer),
                        if (s.mode == TrackMode.trackOnly)
                          _Badge('Track only', cs.surfaceContainerHighest, cs.onSurfaceVariant),
                        if (!s.enabled) _Badge('On demand', cs.surfaceContainerHighest, cs.onSurfaceVariant),
                        for (final cat in s.categories.take(3))
                          _Badge(cat, cs.tertiaryContainer, cs.onTertiaryContainer),
                      ],
                    ),
                    if (running || installing) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: installing ? null : prog?.fraction),
                    ],
                  ],
                ),
              ),
              if (running)
                IconButton(
                  tooltip: 'Stop',
                  onPressed: () => c.cancel(s.id),
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              else if (status == AppStatus.updateAvailable || status == AppStatus.notInstalled)
                IconButton.filledTonal(
                  tooltip: status == AppStatus.notInstalled ? 'Install' : 'Update',
                  onPressed: installing
                      ? null
                      : () async {
                          final o = await c.installLatest(s);
                          if (context.mounted) {
                            toast(context, o == null ? 'Download it first (Check)' : '${s.name}: ${o.message}');
                          }
                        },
                  icon: const Icon(Icons.install_mobile),
                )
              else
                IconButton(tooltip: 'Check now', onPressed: () => c.check(s.id), icon: const Icon(Icons.sync)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Badge(this.text, this.bg, this.fg);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: fg),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}
