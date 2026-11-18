import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import 'package:getterx_core/models.dart';
import 'common.dart';
import 'log_page.dart';
import 'settings_page.dart';
import 'source_detail_page.dart';
import 'source_editor.dart';

class HomePage extends StatelessWidget {
  final AppController c;
  const HomePage(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final sources = c.sources;
        return Scaffold(
          appBar: AppBar(
            title: const Text('GetterX'),
            actions: [
              IconButton(
                tooltip: 'Check all now',
                onPressed: c.busy ? null : () => c.checkAll(),
                icon: c.busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Activity',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LogPage(c))),
                icon: const Icon(Icons.history),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(c))),
                icon: const Icon(Icons.settings),
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
                  actions: [TextButton(onPressed: () => c.credentialError = null, child: const Text('OK'))],
                ),
              Expanded(
                child: sources.isEmpty
                    ? const _Empty()
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: sources.length,
                        itemBuilder: (_, i) => _SourceTile(c, sources[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

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
            'Tap Add and paste a link: GitHub, GitLab, Codeberg, Modrinth, CurseForge, itch.io, F-Droid — or any download page.',
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
  const _SourceTile(this.c, this.s);

  @override
  Widget build(BuildContext context) {
    final running = c.engine.isRunning(s.id);
    final prog = c.progress[s.id];
    final files = s.downloads.expand((d) => d.files).length;
    final sub = [
      '${sourceKindLabel(s.kind)} · ${trackModeLabel(s.mode)}',
      if (s.latestVersionSeen != null) 'Latest: ${s.latestVersionSeen}',
      '$files file${files == 1 ? '' : 's'} · checked ${ago(s.lastChecked)}',
    ].join('\n');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SourceDetailPage(c, s.id))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(child: Icon(kindIcon(s.kind))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.name,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(decoration: s.enabled ? null : TextDecoration.lineThrough),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (s.lastError != null) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: s.lastError!,
                            child: Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(running && prog != null ? prog.message : sub, style: Theme.of(context).textTheme.bodySmall),
                    if (running) ...[const SizedBox(height: 6), LinearProgressIndicator(value: prog?.fraction)],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Check now',
                onPressed: running ? null : () => c.check(s.id),
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
