import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';

import 'package:getterx_core/models.dart';
import 'package:getterx_core/selector.dart';

import 'common.dart';
import 'source_editor.dart';

class SourceDetailPage extends StatelessWidget {
  final AppController c;
  final String id;
  const SourceDetailPage(this.c, this.id, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.byId(id);
        if (s == null) return const Scaffold(body: Center(child: Text('Removed')));
        final running = c.engine.isRunning(id);
        final prog = c.progress[id];
        final folder = c.engine.folderFor(s);
        final active = s.downloads.where((d) => !isArchivedSlot(d.slot)).toList()
          ..sort((a, b) => (b.publishedAt ?? b.downloadedAt).compareTo(a.publishedAt ?? a.downloadedAt));
        final old = s.downloads.where((d) => isArchivedSlot(d.slot)).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(s.name),
            actions: [
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.tune),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SourceEditor(c, s))),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'remove' || v == 'removeFiles') {
                    final del = v == 'removeFiles';
                    if (await confirm(
                      context,
                      'Remove ${s.name}?',
                      del
                          ? 'Stops tracking and DELETES its downloaded files.'
                          : 'Stops tracking. Downloaded files stay on disk.',
                      ok: 'Remove',
                    )) {
                      await c.removeSource(s, deleteFiles: del);
                      if (context.mounted) Navigator.pop(context);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'remove', child: Text('Remove (keep files)')),
                  PopupMenuItem(value: 'removeFiles', child: Text('Remove and delete files')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              ListTile(
                leading: Icon(kindIcon(s.kind)),
                title: Text('${sourceKindLabel(s.kind)} · ${s.ref}'),
                subtitle: Text(
                  '${trackModeLabel(s.mode)}\nChecked ${ago(s.lastChecked)}${s.latestVersionSeen == null ? '' : ' · latest ${s.latestVersionSeen}'}',
                ),
                isThreeLine: true,
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder),
                subtitle: Text(s.downloadDir.isEmpty ? 'Default folder' : 'Custom folder'),
                trailing: Platform.isIOS ? null : const Icon(Icons.open_in_new),
                onTap: Platform.isIOS ? null : () => openFolder(folder),
              ),
              if (s.lastError != null)
                ListTile(
                  leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                  title: const Text('Last check had errors'),
                  subtitle: SelectableText(s.lastError!),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: running
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(prog?.message ?? 'Working…'),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: prog?.fraction),
                        ],
                      )
                    : FilledButton.icon(
                        onPressed: () => c.check(id),
                        icon: const Icon(Icons.sync),
                        label: const Text('Check & download now'),
                      ),
              ),
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
      },
    );
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
