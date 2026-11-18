/// JSON persistence for settings, tracked sources and the activity log.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'credentials.dart';
import 'models.dart';

class AppConfig {
  AppSettings settings;
  List<TrackedSource> sources;
  AppConfig(this.settings, this.sources);

  Map<String, dynamic> toJson() => {
        'format': 1,
        'settings': settings.toJson(),
        'sources': sources.map((s) => s.toJson()).toList(),
      };

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        AppSettings.fromJson((j['settings'] as Map? ?? {}).cast()),
        (j['sources'] as List? ?? const [])
            .map((e) => TrackedSource.fromJson((e as Map).cast()))
            .toList(),
      );
}

class LogEntry {
  final DateTime time;
  final String level; // info | download | delete | error
  final String message;
  final String? sourceId;
  LogEntry(this.level, String message, {this.sourceId, DateTime? time})
      : message = redact(message),
        time = time ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'l': level,
        'm': message,
        if (sourceId != null) 's': sourceId,
      };
  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
      j['l'] as String? ?? 'info', j['m'] as String? ?? '',
      sourceId: j['s'] as String?, time: DateTime.tryParse(j['t'] as String? ?? ''));
}

class ConfigStore {
  final Directory dataDir;
  late AppConfig config;

  ConfigStore(this.dataDir);

  File get _file => File(p.join(dataDir.path, 'config.json'));
  File get _logFile => File(p.join(dataDir.path, 'activity.log'));

  AppConfig _read() {
    if (!_file.existsSync()) return AppConfig(AppSettings(), []);
    try {
      return AppConfig.fromJson(
          (jsonDecode(_file.readAsStringSync()) as Map).cast());
    } catch (_) {
      final bak = File('${_file.path}.bak');
      if (bak.existsSync()) {
        return AppConfig.fromJson((jsonDecode(bak.readAsStringSync()) as Map).cast());
      }
      rethrow;
    }
  }

  Future<AppConfig> load() async {
    await dataDir.create(recursive: true);
    config = _read();
    return config;
  }

  /// Re-reads the file (another process / background task may have written it).
  Future<AppConfig> reload() => load();

  Future<void> _write(AppConfig c) async {
    await dataDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(c.toJson()),
        flush: true);
    if (_file.existsSync()) {
      try {
        await _file.copy('${_file.path}.bak');
      } catch (_) {}
    }
    await tmp.rename(_file.path);
  }

  Future<void> save() => _write(config);

  /// Merges one source into the on-disk state without clobbering changes
  /// made to other sources by another process (e.g. the background task).
  Future<void> saveSource(TrackedSource s) async {
    final disk = _read();
    final i = disk.sources.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      disk.sources[i] = s;
    } else {
      disk.sources.add(s);
    }
    config = AppConfig(config.settings, disk.sources);
    await _write(config);
  }

  Future<void> removeSource(String id) async {
    final disk = _read();
    disk.sources.removeWhere((e) => e.id == id);
    config = AppConfig(config.settings, disk.sources);
    await _write(config);
  }

  /// Saves settings while keeping sources as they are on disk.
  Future<void> saveSettings() async {
    final disk = _read();
    config = AppConfig(config.settings, disk.sources);
    await _write(config);
  }

  Future<void> log(LogEntry e) async {
    try {
      await _logFile.writeAsString('${jsonEncode(e.toJson())}\n',
          mode: FileMode.append, flush: true);
      if (_logFile.lengthSync() > 512 * 1024) {
        final lines = _logFile.readAsLinesSync();
        await _logFile.writeAsString('${lines.skip(lines.length - 1000).join('\n')}\n');
      }
    } catch (_) {}
  }

  List<LogEntry> readLog({int max = 500}) {
    if (!_logFile.existsSync()) return [];
    final lines = _logFile.readAsLinesSync();
    return lines.reversed
        .take(max)
        .map((l) {
          try {
            return LogEntry.fromJson((jsonDecode(l) as Map).cast());
          } catch (_) {
            return null;
          }
        })
        .whereType<LogEntry>()
        .toList();
  }
}
