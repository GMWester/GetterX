// GetterX command line: used by the desktop background scheduler and usable
// on its own (servers, cron, scripts). Shares config with the app.
import 'dart:io';

import 'package:getterx/core/credentials.dart';
import 'package:getterx/core/engine.dart';
import 'package:getterx/core/models.dart';
import 'package:getterx/core/paths.dart';
import 'package:getterx/core/store.dart';

const usage = '''
GetterX CLI

Usage: getterx-cli [--data DIR] <command> [args]

Commands:
  check [name|id ...]        Check (and download) all enabled sources, or the given ones
  list                       List tracked sources
  add <link> [options]       Track a GitHub / Modrinth / CurseForge / itch.io link
      --dir PATH             Download folder for this source
      --mode MODE            latest | newReleases | allReleases | latestPerLoaderAndGameVersion
      --loaders a,b          Mod loaders (fabric,forge,neoforge,quilt)
      --keep-old             Keep superseded versions
      --prerelease           Include pre-releases / betas
  remove <name|id> [--delete-files]
  preview <name|id>          Show what would be downloaded / deleted
  paths                      Show data and download folders

Credentials (optional) are read from environment variables only:
  GETTERX_GITHUB_TOKEN, GETTERX_CURSEFORGE_KEY, GETTERX_ITCH_KEY, GETTERX_MODRINTH_TOKEN
''';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  String? dataDir;
  final di = args.indexOf('--data');
  if (di >= 0 && di + 1 < args.length) {
    dataDir = args[di + 1];
    args.removeRange(di, di + 2);
  }
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.write(usage);
    return;
  }
  final paths = resolveDesktopPaths(overrideDataDir: dataDir);
  final store = ConfigStore(paths.dataDir);
  await store.load();
  final engine = Engine(store, defaultDownloadRoot: paths.defaultDownloadRoot)
    // Secrets only from the environment; the CLI never stores them.
    ..credentials = await EnvCredentialStore().read();
  var code = 0;
  try {
    TrackedSource find(String q) => store.config.sources.firstWhere(
        (s) => s.id == q || s.name.toLowerCase() == q.toLowerCase() || s.ref.toLowerCase() == q.toLowerCase(),
        orElse: () => throw StateError('No source "$q"'));
    switch (args.first) {
      case 'paths':
        stdout.writeln('data:      ${paths.dataDir.path}${paths.portable ? '  (portable)' : ''}');
        stdout.writeln('downloads: ${engine.downloadRoot}');
      case 'list':
        for (final s in store.config.sources) {
          stdout.writeln('${s.enabled ? ' ' : '-'} ${s.name}  [${sourceKindLabel(s.kind)} ${s.ref}]  '
              '${trackModeLabel(s.mode)}  latest=${s.latestVersionSeen ?? '?'}  '
              'files=${s.downloads.expand((d) => d.files).length}  → ${engine.folderFor(s)}');
        }
      case 'add':
        if (args.length < 2) throw ArgumentError('add needs a link');
        final s = await engine.createFromLink(args[1]);
        String? opt(String n) {
          final i = args.indexOf(n);
          return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
        }
        s.downloadDir = opt('--dir') ?? '';
        final mode = opt('--mode');
        if (mode != null) s.mode = TrackMode.values.byName(mode);
        final loaders = opt('--loaders');
        if (loaders != null) s.loaders = loaders.split(',').map((e) => e.trim().toLowerCase()).toList();
        if (args.contains('--keep-old')) s.keepOld = true;
        if (args.contains('--prerelease')) s.channels = ReleaseChannel.values.toSet();
        await store.saveSource(s);
        stdout.writeln('Added ${s.name} (${s.id}) → ${engine.folderFor(s)}');
      case 'remove':
        final s = find(args[1]);
        if (args.contains('--delete-files')) {
          stdout.writeln('Deleted ${await engine.deleteAllFiles(s)} files');
        }
        await store.removeSource(s.id);
        stdout.writeln('Removed ${s.name}');
      case 'preview':
        final s = find(args[1]);
        final plan = await engine.preview(s);
        for (final d in plan.downloads) {
          stdout.writeln('+ ${d.release.version}  ${d.folder}  ${d.files.map((f) => f.name).join(', ')}');
        }
        for (final d in plan.delete) {
          stdout.writeln('- ${d.version}  (${d.files.length} files)');
        }
        for (final d in plan.archive) {
          stdout.writeln('~ ${d.version}  kept as old version');
        }
        if (plan.isEmpty) stdout.writeln('Up to date');
      case 'check':
        final ids = args.length > 1 ? args.skip(1).map((q) => find(q).id).toList() : null;
        final results = ids == null
            ? await engine.checkAll()
            : [for (final id in ids) await engine.check(id)];
        for (final r in results) {
          final news = r.downloaded.map((d) => d.version).toSet();
          stdout.writeln('${r.ok ? 'OK ' : 'ERR'} ${r.source.name}: '
              '${news.isEmpty ? 'up to date' : 'downloaded ${news.join(', ')}'}'
              '${r.deletedFiles > 0 ? ', removed ${r.deletedFiles} old files' : ''}');
          for (final e in r.errors) {
            stderr.writeln('    $e');
          }
          if (!r.ok) code = 2;
        }
      default:
        stdout.write(usage);
        code = 64;
    }
  } catch (e) {
    stderr.writeln('Error: $e');
    code = 1;
  } finally {
    engine.dispose();
  }
  exit(code);
}
