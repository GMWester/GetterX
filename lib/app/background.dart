/// Automatic checks when GetterX is not in the foreground.
///  - Android / iOS: WorkManager / BGTaskScheduler periodic task.
///  - Windows / macOS / Linux: an OS scheduler entry (Task Scheduler,
///    launchd, systemd user timer) runs `GetterX --background-check`, which
///    checks without showing a window and exits.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:workmanager/workmanager.dart';

import '../core/engine.dart';
import '../core/store.dart';
import 'app_paths.dart';
import 'secure_credentials.dart';

const bgTaskName = 'io.github.gmwester.getterx.check';

/// Runs one check of all enabled sources. Used by every background path.
Future<bool> runBackgroundCheck() async {
  final paths = await resolveAppPaths();
  final store = ConfigStore(paths.dataDir);
  await store.load();
  final engine = Engine(store, defaultDownloadRoot: paths.defaultDownloadRoot);
  try {
    engine.credentials = await SecureCredentialStore().read();
  } catch (_) {
    // Keychain unavailable (e.g. locked): continue with public access only.
  }
  try {
    await engine.checkAll();
    await store.log(LogEntry('info', 'Background check finished'));
    return true;
  } catch (e) {
    await store.log(LogEntry('error', 'Background check failed: $e'));
    return false;
  } finally {
    engine.dispose();
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    return runBackgroundCheck();
  });
}

bool get _mobile => Platform.isAndroid || Platform.isIOS;

Future<void> initBackground() async {
  if (_mobile) await Workmanager().initialize(callbackDispatcher);
}

/// Enables / disables automatic background checks for the current platform.
Future<String?> configureBackground({required bool enabled, required int intervalMinutes}) async {
  final minutes = intervalMinutes.clamp(15, 24 * 60);
  try {
    if (_mobile) {
      if (enabled) {
        await Workmanager().registerPeriodicTask(
          bgTaskName,
          bgTaskName,
          frequency: Duration(minutes: minutes),
          constraints: Constraints(networkType: NetworkType.connected, requiresStorageNotLow: true),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        );
      } else {
        await Workmanager().cancelByUniqueName(bgTaskName);
      }
      return null;
    }
    final exe = Platform.resolvedExecutable;
    if (Platform.isWindows) {
      if (!enabled) {
        await Process.run('schtasks', ['/Delete', '/F', '/TN', 'GetterX Check']);
        return null;
      }
      final r = await Process.run('schtasks', [
        '/Create',
        '/F',
        '/TN',
        'GetterX Check',
        '/SC',
        'MINUTE',
        '/MO',
        '$minutes',
        '/TR',
        '"$exe" --background-check',
      ]);
      return r.exitCode == 0 ? null : '${r.stderr}'.trim();
    }
    final home = Platform.environment['HOME']!;
    if (Platform.isMacOS) {
      final plist = File(p.join(home, 'Library', 'LaunchAgents', '$bgTaskName.plist'));
      await Process.run('launchctl', ['unload', plist.path]);
      if (!enabled) {
        if (plist.existsSync()) await plist.delete();
        return null;
      }
      await plist.parent.create(recursive: true);
      await plist.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$bgTaskName</string>
  <key>ProgramArguments</key><array><string>${_xml(exe)}</string><string>--background-check</string></array>
  <key>StartInterval</key><integer>${minutes * 60}</integer>
  <key>RunAtLoad</key><false/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
''');
      final r = await Process.run('launchctl', ['load', plist.path]);
      return r.exitCode == 0 ? null : '${r.stderr}'.trim();
    }
    if (Platform.isLinux) {
      final dir = Directory(p.join(home, '.config', 'systemd', 'user'));
      final svc = File(p.join(dir.path, 'getterx-check.service'));
      final timer = File(p.join(dir.path, 'getterx-check.timer'));
      if (!enabled) {
        await Process.run('systemctl', ['--user', 'disable', '--now', 'getterx-check.timer']);
        for (final f in [svc, timer]) {
          if (f.existsSync()) await f.delete();
        }
        return null;
      }
      await dir.create(recursive: true);
      final target = Platform.environment['APPIMAGE'] ?? exe;
      await svc.writeAsString('''[Unit]
Description=GetterX background check
After=graphical-session.target network-online.target

[Service]
Type=oneshot
ExecStart="$target" --background-check
''');
      await timer.writeAsString('''[Unit]
Description=Run GetterX checks periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${minutes}min
Persistent=true

[Install]
WantedBy=timers.target
''');
      await Process.run('systemctl', ['--user', 'daemon-reload']);
      final r = await Process.run('systemctl', ['--user', 'enable', '--now', 'getterx-check.timer']);
      return r.exitCode == 0 ? null : '${r.stderr}'.trim();
    }
  } catch (e) {
    return '$e';
  }
  return null;
}

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
