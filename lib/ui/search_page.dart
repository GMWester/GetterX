import 'dart:async';

import 'package:getterx_core/models.dart';
import 'package:getterx_core/search.dart';
import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import 'common.dart';
import 'source_editor.dart';

/// Search mods, modpacks, resource packs, shaders, data packs, plugins and
/// repositories across all searchable sources.
class SearchPage extends StatefulWidget {
  final AppController c;
  const SearchPage(this.c, {super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _q = TextEditingController();
  ContentType _type = ContentType.any;
  final Set<SourceKind> _kinds = searchableKinds.keys.toSet();
  SearchOutcome? _out;
  bool _busy = false;
  Timer? _debounce;
  int _gen = 0;

  Future<void> _run() async {
    final q = _q.text.trim();
    if (q.length < 2) return;
    final gen = ++_gen;
    setState(() => _busy = true);
    final out = await widget.c.searcher.search(q, kinds: _kinds, type: _type);
    if (!mounted || gen != _gen) return;
    setState(() {
      _out = out;
      _busy = false;
    });
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _run);
  }

  Future<void> _track(SearchResult r) async {
    try {
      final s = await widget.c.resolveLink(r.link);
      if (!mounted) return;
      final saved = await Navigator.push<TrackedSource>(
        context,
        MaterialPageRoute(builder: (_) => SourceEditor(widget.c, s, isNew: true)),
      );
      if (saved != null) {
        widget.c.check(saved.id);
        if (mounted) toast(context, 'Tracking ${saved.name}');
      }
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final types = ContentType.values;
    final results = _out?.results ?? const <SearchResult>[];
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search mods, modpacks, plugins, repos…',
            border: InputBorder.none,
          ),
          onChanged: (_) => _changed(),
          onSubmitted: (_) => _run(),
        ),
        actions: [IconButton(onPressed: _run, icon: const Icon(Icons.search))],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                for (final t in types)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(contentTypeLabel(t)),
                      selected: _type == t,
                      onSelected: (_) {
                        setState(() => _type = t);
                        _run();
                      },
                    ),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                for (final k in searchableKinds.keys)
                  if (_type == ContentType.any || searchableKinds[k]!.contains(_type))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        avatar: Icon(kindIcon(k), size: 16),
                        label: Text(sourceKindLabel(k)),
                        selected: _kinds.contains(k),
                        onSelected: (v) {
                          setState(() => v ? _kinds.add(k) : _kinds.remove(k));
                          _run();
                        },
                      ),
                    ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_out != null && _out!.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'No answer from: ${_out!.errors.keys.map(sourceKindLabel).join(', ')}'
                '${_out!.errors.containsKey(SourceKind.curseforge) ? ' (a CurseForge API key in Settings → Accounts helps)' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: _out == null
                ? const Center(child: Text('Type at least two letters'))
                : results.isEmpty
                ? const Center(child: Text('No results'))
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final r = results[i];
                      final tracked = widget.c.sources.any((s) => s.pageUrl == r.link);
                      return ListTile(
                        leading: r.iconUrl != null && r.iconUrl!.startsWith('https://')
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  r.iconUrl!,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Icon(kindIcon(r.kind)),
                                ),
                              )
                            : CircleAvatar(child: Icon(kindIcon(r.kind))),
                        title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            sourceKindLabel(r.kind),
                            ?r.type,
                            if (r.author != null) 'by ${r.author}',
                            if (r.downloads != null)
                              r.type == 'repository' ? '★ ${_n(r.downloads!)}' : '${_n(r.downloads!)} downloads',
                            if (r.description != null) '\n${r.description}',
                          ].join(' · ').replaceAll(' · \n', '\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: r.description != null,
                        trailing: tracked
                            ? const Icon(Icons.check_circle)
                            : FilledButton.tonal(onPressed: () => _track(r), child: const Text('Track')),
                        onTap: () => _track(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static String _n(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : v >= 1000
      ? '${(v / 1000).toStringAsFixed(1)}k'
      : '$v';
}
