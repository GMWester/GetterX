/// Decides what to download / delete for a tracked source. Pure and testable.
library;

import 'models.dart';
import 'platform_match.dart';
import 'version_utils.dart';

class PlannedDownload {
  final String slot;
  final RemoteRelease release;
  final List<RemoteFile> files;

  /// Folder relative to the source's folder (may be empty).
  final String folder;
  const PlannedDownload(this.slot, this.release, this.files, this.folder);
}

class SyncPlan {
  final List<PlannedDownload> downloads;

  /// Records whose files should be deleted from disk.
  final List<DownloadRecord> delete;

  /// Records that are superseded but kept on disk (keepOld): slot renamed.
  final List<DownloadRecord> archive;
  final DateTime? newBaseline;
  final String? newestVersion;
  const SyncPlan(this.downloads, this.delete, this.archive, {this.newBaseline, this.newestVersion});

  bool get isEmpty => downloads.isEmpty && delete.isEmpty && archive.isEmpty;
}

const archivedMarker = '#old#';
bool isArchivedSlot(String slot) => slot.contains(archivedMarker);
String baseSlot(String slot) => slot.split(archivedMarker).first;

int _stability(ReleaseChannel c) => switch (c) {
  ReleaseChannel.release => 0,
  ReleaseChannel.beta => 1,
  ReleaseChannel.alpha => 2,
};

/// Newest first; releases without a date keep API order after dated ones of equal rank.
int compareNewest(RemoteRelease a, RemoteRelease b) {
  final da = a.publishedAt, db = b.publishedAt;
  if (da != null && db != null && da != db) return db.compareTo(da);
  return a.order.compareTo(b.order);
}

String sanitizeName(String s) {
  var out = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  if (out.isEmpty) out = '_';
  const reserved = {'con', 'prn', 'aux', 'nul', 'com1', 'lpt1'};
  if (reserved.contains(out.toLowerCase())) out = '_$out';
  return out.length > 120 ? out.substring(0, 120) : out;
}

List<RemoteFile> filterFiles(TrackedSource s, RemoteRelease r, PlatformInfo platform) {
  Iterable<RemoteFile> files = r.files;
  if (s.isMod && s.primaryFileOnly && files.any((f) => f.primary)) {
    files = files.where((f) => f.primary);
  }
  if (s.includeFilesRegex.trim().isNotEmpty) {
    final re = RegExp(s.includeFilesRegex, caseSensitive: false);
    files = files.where((f) => re.hasMatch(f.name));
  }
  if (s.excludeFilesRegex.trim().isNotEmpty) {
    final re = RegExp(s.excludeFilesRegex, caseSensitive: false);
    files = files.where((f) => !re.hasMatch(f.name));
  }
  if (s.fileTypes.isNotEmpty) {
    files = files.where((f) => s.fileTypes.any((t) => f.name.toLowerCase().endsWith('.${t.toLowerCase()}')));
  }
  var list = files.toList();
  if (!s.isMod && s.onlyPlatformFiles) {
    final binaries = list.where((f) => !f.isSourceArchive && f.platforms.isEmpty).toList();
    final keep = pickPlatformFiles(binaries.map((f) => f.name).toList(), platform).toSet();
    list = list
        .where(
          (f) =>
              f.isSourceArchive || (f.platforms.isNotEmpty ? f.platforms.contains(platform.os) : keep.contains(f.name)),
        )
        .toList();
  }
  return list;
}

/// Game versions a release counts for, after snapshot filtering / grouping.
List<String> effectiveGameVersions(TrackedSource s, RemoteRelease r) {
  final out = <String>{};
  for (final g in r.gameVersions) {
    if (!s.includeSnapshots && !isReleaseGameVersion(g)) continue;
    out.add(s.groupMinorVersions && isReleaseGameVersion(g) ? minorGroup(g) : g);
  }
  return out.toList();
}

SyncPlan planSync(TrackedSource s, List<RemoteRelease> releases, {PlatformInfo? platform, DateTime? now}) {
  platform ??= PlatformInfo.current();
  final candidates = <RemoteRelease, List<RemoteFile>>{};
  final sorted = [...releases]..sort(compareNewest);
  final versionRe = s.versionRegex.trim().isEmpty ? null : RegExp(s.versionRegex, caseSensitive: false);
  for (final r in sorted) {
    if (!s.channels.contains(r.channel)) continue;
    if (versionRe != null && !versionRe.hasMatch(r.version) && !versionRe.hasMatch(r.title)) continue;
    if (s.skippedVersion != null && r.version == s.skippedVersion) continue;
    if (s.loaders.isNotEmpty && r.loaders.isNotEmpty && !r.loaders.any((l) => s.loaders.contains(l))) {
      continue;
    }
    final files = filterFiles(s, r, platform);
    if (files.isEmpty) continue;
    candidates[r] = files;
  }
  final newest = candidates.keys.isEmpty ? null : candidates.keys.first;
  if (candidates.isEmpty) {
    // Nothing matched (or the API returned nothing): never delete on an empty result.
    return const SyncPlan([], [], []);
  }

  // slot -> (release, folder)
  final wanted = <String, (RemoteRelease, String)>{};
  DateTime? newBaseline;

  RemoteRelease? pickBest(Iterable<RemoteRelease> rs) {
    final list = rs.toList();
    if (list.isEmpty) return null;
    if (s.preferStable) {
      list.sort((a, b) {
        final c = _stability(a.channel).compareTo(_stability(b.channel));
        return c != 0 ? c : compareNewest(a, b);
      });
    }
    return list.first;
  }

  switch (s.mode) {
    case TrackMode.trackOnly:
      return SyncPlan(const [], const [], const [], newestVersion: pickBest(candidates.keys)?.version);
    case TrackMode.latest:
      final best = pickBest(candidates.keys);
      if (best != null) wanted['latest'] = (best, sanitizeName(best.version));
    case TrackMode.newReleases:
    case TrackMode.allReleases:
      var list = candidates.keys.toList();
      if (s.mode == TrackMode.newReleases) {
        final base = s.baseline ?? newest?.publishedAt;
        if (s.baseline == null) newBaseline = base ?? now ?? DateTime.now();
        final known = s.downloads.map((d) => d.releaseId).toSet();
        list = list
            .where(
              (r) =>
                  known.contains(r.id) ||
                  (r.publishedAt == null ? identical(r, newest) : base == null || !r.publishedAt!.isBefore(base)),
            )
            .toList();
      }
      // Retention: how many release folders to keep.
      final keep = !s.keepOld ? 1 : s.keepCount;
      if (s.mode == TrackMode.newReleases && keep > 0 && list.length > keep) {
        list = list.sublist(0, keep);
      }
      final used = <String>{};
      for (final r in list) {
        var folder = sanitizeName(r.version.isEmpty ? r.id : r.version);
        if (!used.add(folder)) folder = '${folder}_${r.id}';
        wanted['release:${r.id}'] = (r, folder);
      }
    case TrackMode.latestPerLoaderAndGameVersion:
      final byKey = <String, List<RemoteRelease>>{};
      final allGames = <String>{};
      for (final r in candidates.keys) {
        allGames.addAll(effectiveGameVersions(s, r));
      }
      var allowedGames = allGames;
      if (s.gameVersions.isNotEmpty) {
        final want = s.gameVersions.map((g) => s.groupMinorVersions ? minorGroup(g) : g).toSet();
        allowedGames = allowedGames.intersection(want);
      }
      if (s.gameVersionLimit > 0) {
        final releasesOnly = allowedGames.where(isReleaseGameVersion).toList()..sort((a, b) => compareVersions(b, a));
        final top = releasesOnly.take(s.gameVersionLimit).toSet();
        allowedGames = allowedGames.where((g) => top.contains(g) || !isReleaseGameVersion(g)).toSet();
      }
      for (final r in candidates.keys) {
        var games = effectiveGameVersions(s, r).where(allowedGames.contains).toList();
        if (r.gameVersions.isEmpty) games = ['any'];
        if (games.isEmpty) continue;
        var loaders = r.loaders.where((l) => s.loaders.isEmpty || s.loaders.contains(l)).toList();
        if (r.loaders.isEmpty) loaders = ['any'];
        for (final g in games) {
          for (final l in loaders) {
            (byKey['$l|$g'] ??= []).add(r);
          }
        }
      }
      final best = {for (final e in byKey.entries) e.key: pickBest(e.value)!};
      // One file that is the newest for several game versions of a loader
      // (e.g. a jar for 26.1, 26.1.1 and 26.1.2) is stored once, in a folder
      // named after the range, instead of once per game version.
      final gamesFor = <String, List<String>>{};
      for (final e in best.entries) {
        final parts = e.key.split('|');
        (gamesFor['${parts[0]}|${e.value.id}'] ??= []).add(parts[1]);
      }
      for (final e in best.entries) {
        final parts = e.key.split('|');
        final games = gamesFor['${parts[0]}|${e.value.id}']!..sort(compareVersions);
        final label = games.length == 1 ? games.first : '${games.first}-${games.last}';
        final folder = [
          if (label != 'any') sanitizeName(label),
          if (parts[0] != 'any') sanitizeName(parts[0]),
        ].join('/');
        wanted['slot:${e.key}'] = (e.value, folder);
      }
  }

  // Diff against current records.
  final active = {for (final d in s.downloads.where((d) => !isArchivedSlot(d.slot))) d.slot: d};
  final downloads = <PlannedDownload>[];
  final delete = <DownloadRecord>[];
  final archive = <DownloadRecord>[];
  final isArchiveMode = s.mode == TrackMode.newReleases || s.mode == TrackMode.allReleases;

  for (final e in wanted.entries) {
    final cur = active[e.key];
    if (cur != null && cur.releaseId == e.value.$1.id) continue;
    downloads.add(PlannedDownload(e.key, e.value.$1, candidates[e.value.$1]!, e.value.$2));
    if (cur != null) {
      (s.keepOld && !isArchiveMode ? archive : delete).add(cur);
    }
  }
  for (final e in active.entries) {
    if (wanted.containsKey(e.key)) continue;
    // Slot no longer wanted (filters changed, retention, release removed upstream).
    if (isArchiveMode) {
      final stillListed = releases.any((r) => 'release:${r.id}' == e.key);
      // Never delete archived releases just because they vanished upstream.
      if (!stillListed && s.mode == TrackMode.allReleases) continue;
      if (s.mode == TrackMode.allReleases) {
        // allReleases keeps everything that still matches; delete only filtered-out ones.
        delete.add(e.value);
        continue;
      }
      (s.keepOld && s.keepCount == 0 ? archive : delete).add(e.value);
    } else {
      (s.keepOld ? archive : delete).add(e.value);
    }
  }

  // Limit the number of archived (old) records per base slot.
  if (s.keepOld && s.keepCount > 0 && !isArchiveMode) {
    final groups = <String, List<DownloadRecord>>{};
    for (final d in [...s.downloads.where((d) => isArchivedSlot(d.slot)), ...archive]) {
      (groups[baseSlot(d.slot)] ??= []).add(d);
    }
    for (final g in groups.values) {
      g.sort((a, b) => (b.publishedAt ?? b.downloadedAt).compareTo(a.publishedAt ?? a.downloadedAt));
      for (final d in g.skip(s.keepCount)) {
        archive.remove(d);
        delete.add(d);
      }
    }
  }

  return SyncPlan(downloads, delete, archive, newBaseline: newBaseline, newestVersion: newest?.version);
}

/// Extension of a file name ("tar.gz" aware), lower-case, without dot.
String fileExtension(String name) {
  final n = name.toLowerCase();
  for (final double in ['tar.gz', 'tar.xz', 'tar.zst', 'tar.bz2']) {
    if (n.endsWith('.$double')) return double;
  }
  final i = n.lastIndexOf('.');
  return i < 0 || i == n.length - 1 ? '' : n.substring(i + 1);
}

/// Turns chosen file names into a regex that still matches them in future
/// releases: stand-alone version numbers become wildcards, while things like
/// `x64`, `arm64` or `win32` stay literal. e.g.
/// `App-1.2.3-win-x64.exe` -> `^App-v?\d+(?:[._-]\d+)*-win-x64\.exe$`.
String patternForFiles(Iterable<String> names) {
  const wildcard = r'v?\d+(?:[._-]\d+)*';
  final version = RegExp(r'(?<![A-Za-z0-9])v?\d+(?:[._-]\d+)*(?![A-Za-z0-9])');
  final parts = <String>{};
  for (final n in names) {
    final buf = StringBuffer('^');
    var last = 0;
    for (final m in version.allMatches(n)) {
      buf
        ..write(RegExp.escape(n.substring(last, m.start)))
        ..write(wildcard);
      last = m.end;
    }
    buf
      ..write(RegExp.escape(n.substring(last)))
      ..write(r'$');
    parts.add(buf.toString());
  }
  return parts.join('|');
}
