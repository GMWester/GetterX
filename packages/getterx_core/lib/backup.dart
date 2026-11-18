/// Export / import of tracked sources and settings (never secrets).
library;

import 'dart:convert';

import 'models.dart';

String exportBackup(AppSettings settings, List<TrackedSource> sources, {bool includeHistory = false}) {
  return const JsonEncoder.withIndent('  ').convert({
    'getterxBackup': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'settings': settings.toJson(),
    'sources': [
      for (final s in sources)
        {...s.toJson(), if (!includeHistory) 'downloads': <Object>[], if (!includeHistory) 'baseline': null},
    ],
  });
}

class BackupContents {
  final AppSettings? settings;
  final List<TrackedSource> sources;
  const BackupContents(this.settings, this.sources);
}

/// Accepts GetterX backups and plain lists of links (one per line).
BackupContents parseBackup(String text) {
  final t = text.trim();
  if (t.startsWith('{')) {
    final j = (jsonDecode(t) as Map).cast<String, dynamic>();
    if (j['getterxBackup'] == null && j['sources'] == null) throw const FormatException('Not a GetterX backup');
    return BackupContents(j['settings'] is Map ? AppSettings.fromJson((j['settings'] as Map).cast()) : null, [
      for (final s in (j['sources'] as List? ?? const [])) TrackedSource.fromJson((s as Map).cast()),
    ]);
  }
  throw const FormatException('Not a GetterX backup');
}

/// Links (one per line) from a text list / Obtainium-style export, for "Import links".
List<String> linksFromText(String text) {
  final t = text.trim();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      // Obtainium / ObtainX export: {"apps":[{"url":...}]}
      if (j is Map && j['apps'] is List) {
        return [
          for (final a in j['apps'] as List)
            if (a is Map && a['url'] is String) a['url'] as String,
        ];
      }
    } catch (_) {}
  }
  return RegExp(r'https://[^\s"<>]+').allMatches(t).map((m) => m[0]!).toSet().toList();
}
