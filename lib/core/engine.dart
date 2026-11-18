/// Runs checks: fetch releases -> plan -> download -> prune -> save.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'link_parser.dart';
import 'models.dart';
import 'platform_match.dart';
import 'selector.dart';
import 'sources/curseforge.dart';
import 'sources/github.dart';
import 'sources/itchio.dart';
import 'sources/modrinth.dart';
import 'sources/source.dart';
import 'store.dart';

class CheckResult {
  final TrackedSource source;
  final List<DownloadRecord> downloaded;
  final int deletedFiles;
  final List<String> errors;
  CheckResult(this.source, this.downloaded, this.deletedFiles, this.errors);
  bool get ok => errors.isEmpty;
}

class Progress {
  final String sourceId;
  final String message;
  final double? fraction;
  Progress(this.sourceId, this.message, [this.fraction]);
}

class Engine {
  final ConfigStore store;
  final http.Client client;
  final PlatformInfo platform;

  /// Used when settings.downloadDir is empty.
  final String defaultDownloadRoot;
  final _progress = StreamController<Progress>.broadcast();
  final _running = <String>{};

  Engine(this.store, {http.Client? client, PlatformInfo? platform, required this.defaultDownloadRoot})
      : client = client ?? http.Client(),
        platform = platform ?? PlatformInfo.current();

  Stream<Progress> get progress => _progress.stream;
  bool isRunning(String id) => _running.contains(id);
  bool get anyRunning => _running.isNotEmpty;

  AppSettings get settings => store.config.settings;

  ReleaseSource sourceFor(SourceKind k) => switch (k) {
        SourceKind.github => GitHubSource(client, token: settings.githubToken),
        SourceKind.modrinth => ModrinthSource(client),
        SourceKind.curseforge => CurseForgeSource(client,
            apiKey: settings.curseforgeApiKey, baseUrl: settings.curseforgeBaseUrl),
        SourceKind.itchio => ItchSource(client, apiKey: settings.itchApiKey),
      };

  String get downloadRoot =>
      settings.downloadDir.trim().isNotEmpty ? settings.downloadDir.trim() : defaultDownloadRoot;

  String folderFor(TrackedSource s) => s.downloadDir.trim().isNotEmpty
      ? s.downloadDir.trim()
      : p.join(downloadRoot, sanitizeName(s.name));

  /// Resolves a pasted link / id into a new source (not yet saved).
  Future<TrackedSource> createFromLink(String input, {SourceKind? forceKind}) async {
    final parsed = parseSourceLink(input, forceKind: forceKind);
    if (parsed == null) {
      throw SourceException('Unrecognised link. Paste a GitHub, Modrinth or CurseForge URL.');
    }
    final info = await sourceFor(parsed.kind).fetchProject(parsed.ref);
    final ref = parsed.kind == SourceKind.github ? info.id : parsed.ref;
    return TrackedSource(
      id: '${parsed.kind.name}:${ref.toLowerCase()}:${DateTime.now().microsecondsSinceEpoch}',
      kind: parsed.kind,
      ref: parsed.kind == SourceKind.curseforge || parsed.kind == SourceKind.itchio ? info.id : ref,
      name: info.name,
      onlyPlatformFiles: !(parsed.kind == SourceKind.modrinth || parsed.kind == SourceKind.curseforge),
    );
  }

  Future<List<RemoteRelease>> fetchReleases(TrackedSource s) {
    final full = s.mode == TrackMode.allReleases ||
        s.mode == TrackMode.latestPerLoaderAndGameVersion ||
        (s.mode == TrackMode.newReleases && s.baseline != null &&
            DateTime.now().difference(s.lastChecked ?? DateTime(0)).inDays > 30);
    return sourceFor(s.kind).fetchReleases(s, full: full);
  }

  /// Preview: what would be downloaded / deleted, without touching disk.
  Future<SyncPlan> preview(TrackedSource s) async =>
      planSync(s, await fetchReleases(s), platform: platform);

  Future<List<CheckResult>> checkAll({bool onlyEnabled = true}) async {
    await store.reload();
    final results = <CheckResult>[];
    for (final s in [...store.config.sources]) {
      if (onlyEnabled && !s.enabled) continue;
      results.add(await check(s.id));
    }
    return results;
  }

  Future<CheckResult> check(String sourceId) async {
    await store.reload();
    final s = store.config.sources.firstWhere((e) => e.id == sourceId);
    if (!_running.add(sourceId)) {
      return CheckResult(s, [], 0, ['Already running']);
    }
    final errors = <String>[];
    final newRecords = <DownloadRecord>[];
    var deleted = 0;
    try {
      _emit(s, 'Checking ${s.name}…');
      final releases = await fetchReleases(s);
      final plan = planSync(s, releases, platform: platform);
      if (plan.newBaseline != null) s.baseline = plan.newBaseline;
      if (plan.newestVersion != null) s.latestVersionSeen = plan.newestVersion;
      final root = folderFor(s);

      // Files already fetched in this run, so a release that fills several
      // slots (e.g. one jar for 1.21.10 and 1.21.11) is downloaded once.
      final fetched = <String, String>{};
      final failedSlots = <String>{};
      var n = 0;
      for (final pd in plan.downloads) {
        n++;
        final dir = p.join(root, pd.folder);
        final paths = <String>[];
        try {
          for (final rf in pd.files) {
            final dest = File(p.join(dir, sanitizeName(rf.name)));
            final key = '${pd.release.id}/${rf.name}';
            final prev = fetched[key];
            if (prev != null && p.equals(prev, dest.path)) {
              // same file
            } else if (prev != null) {
              await dest.parent.create(recursive: true);
              await File(prev).copy(dest.path);
            } else if (await fileMatches(dest, rf)) {
              // Already on disk (e.g. a previous run was interrupted).
            } else {
              _emit(s, 'Downloading ${rf.name}', 0);
              await Downloader(client).download(rf, dest, onProgress: (r, t) {
                _emit(s, 'Downloading ${rf.name} ($n/${plan.downloads.length})',
                    t == null || t == 0 ? null : r / t);
              });
            }
            fetched[key] = dest.path;
            paths.add(dest.path);
          }
          final rec = DownloadRecord(
            slot: pd.slot,
            releaseId: pd.release.id,
            version: pd.release.version,
            publishedAt: pd.release.publishedAt,
            files: paths,
            downloadedAt: DateTime.now(),
          );
          newRecords.add(rec);
          await store.log(LogEntry('download',
              '${s.name}: ${pd.release.version}${pd.folder.isEmpty ? '' : ' → ${pd.folder}'}',
              sourceId: s.id));
        } catch (e) {
          failedSlots.add(pd.slot);
          errors.add('${pd.release.version}: $e');
          await store.log(LogEntry('error', '${s.name}: ${pd.release.version}: $e', sourceId: s.id));
          // Remove partial files of this slot that are not used elsewhere.
        }
      }

      // Never drop the old version of a slot whose replacement failed.
      final toDelete = plan.delete.where((d) => !failedSlots.contains(d.slot)).toList();
      final toArchive = plan.archive.where((d) => !failedSlots.contains(d.slot)).toList();
      final removedIds = {...toDelete, ...toArchive};

      final remaining = <DownloadRecord>[
        for (final d in s.downloads)
          if (!removedIds.contains(d)) d,
        for (final d in toArchive)
          DownloadRecord(
            slot: '${baseSlot(d.slot)}$archivedMarker${d.releaseId}',
            releaseId: d.releaseId,
            version: d.version,
            publishedAt: d.publishedAt,
            files: d.files,
            downloadedAt: d.downloadedAt,
          ),
      ];
      // Replace records for slots that were re-downloaded.
      final newSlots = newRecords.map((r) => r.slot).toSet();
      remaining.removeWhere((d) => newSlots.contains(d.slot));
      final kept = [...remaining, ...newRecords];

      final inUse = kept.expand((d) => d.files).map(p.normalize).toSet();
      for (final d in toDelete) {
        for (final f in d.files) {
          if (inUse.contains(p.normalize(f))) continue;
          try {
            final file = File(f);
            if (file.existsSync()) {
              await file.delete();
              deleted++;
            }
            await _pruneEmptyDirs(file.parent, root);
          } catch (e) {
            errors.add('Could not delete $f: $e');
          }
        }
        await store.log(LogEntry('delete', '${s.name}: removed ${d.version}', sourceId: s.id));
      }
      s.downloads = kept;
      s.lastError = errors.isEmpty ? null : errors.join('\n');
    } catch (e) {
      errors.add('$e');
      s.lastError = '$e';
      await store.log(LogEntry('error', '${s.name}: $e', sourceId: s.id));
    } finally {
      s.lastChecked = DateTime.now();
      _running.remove(sourceId);
      await store.saveSource(s);
      _emit(s, errors.isEmpty ? 'Up to date' : 'Finished with errors', 1);
    }
    return CheckResult(s, newRecords, deleted, errors);
  }

  /// Deletes a source's downloaded files (used when removing a source).
  Future<int> deleteAllFiles(TrackedSource s) async {
    var n = 0;
    final root = folderFor(s);
    for (final d in s.downloads) {
      for (final f in d.files) {
        final file = File(f);
        if (file.existsSync()) {
          await file.delete();
          n++;
        }
        await _pruneEmptyDirs(file.parent, root);
      }
    }
    return n;
  }

  Future<void> _pruneEmptyDirs(Directory dir, String stopAt) async {
    var d = dir;
    final stop = p.normalize(stopAt);
    while (p.isWithin(stop, d.path)) {
      if (!d.existsSync() || d.listSync().isNotEmpty) return;
      await d.delete();
      d = d.parent;
    }
  }

  void _emit(TrackedSource s, String msg, [double? f]) {
    if (!_progress.isClosed) _progress.add(Progress(s.id, msg, f));
  }

  void dispose() {
    _progress.close();
    client.close();
  }
}
