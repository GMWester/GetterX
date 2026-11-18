/// What happens after a check downloaded something: detect the Android package,
/// optionally scan with VirusTotal, install (silently where possible), notify.
library;

import 'dart:io';

import 'package:getterx_core/credentials.dart';
import 'package:getterx_core/engine.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/store.dart';
import 'package:getterx_core/version_utils.dart';
import 'package:getterx_core/virustotal.dart';
import 'package:getterx_installer/getterx_installer.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'desktop_installer.dart';
import 'notifications.dart';

/// Status of a tracked app compared with what is installed on this device.
enum AppStatus { upToDate, updateAvailable, deviceAhead, sameVersionDifferentName, unclear, notInstalled, notAnApp }

String appStatusLabel(AppStatus s) => switch (s) {
  AppStatus.upToDate => 'Up to date',
  AppStatus.updateAvailable => 'Update available',
  AppStatus.deviceAhead => 'Installed version is newer',
  AppStatus.sameVersionDifferentName => 'Up to date (different version label)',
  AppStatus.unclear => 'Version unclear',
  AppStatus.notInstalled => 'Not installed',
  AppStatus.notAnApp => '',
};

String _strip(String v) => v.trim().replaceFirst(RegExp(r'^[vV](?=\d)'), '');

/// Compares the installed app (Android) with the newest downloaded/seen version.
AppStatus statusFor(TrackedSource s, AppPackageInfo? installed) {
  if (s.packageId == null || s.packageId!.isEmpty) return AppStatus.notAnApp;
  if (installed == null) return AppStatus.notInstalled;
  if (s.apkVersionCode != null && installed.versionCode != 0) {
    if (installed.versionCode == s.apkVersionCode) return AppStatus.upToDate;
    if (installed.versionCode > s.apkVersionCode!) return AppStatus.deviceAhead;
    return AppStatus.updateAvailable;
  }
  final latest = s.apkVersionName ?? s.latestVersionSeen;
  final mine = installed.versionName;
  if (latest == null || mine == null) return AppStatus.unclear;
  final a = _strip(mine), b = _strip(latest);
  if (a == b) return AppStatus.upToDate;
  final num = RegExp(r'\d+(?:\.\d+)+');
  final na = num.firstMatch(a)?[0], nb = num.firstMatch(b)?[0];
  if (na == null || nb == null) return AppStatus.unclear;
  final c = compareVersions(na, nb);
  if (c == 0) return AppStatus.sameVersionDifferentName;
  return c > 0 ? AppStatus.deviceAhead : AppStatus.updateAvailable;
}

class InstallOutcome {
  final TrackedSource source;
  final String file;
  final bool ok;
  final bool needsUser;
  final String message;
  const InstallOutcome(this.source, this.file, this.ok, this.message, {this.needsUser = false});
}

class InstallPipeline {
  final ConfigStore store;
  final http.Client client;
  final Credentials credentials;
  final bool background;
  InstallPipeline(this.store, this.client, this.credentials, {required this.background});

  /// Runs after a check. Returns the install attempts that were made.
  Future<List<InstallOutcome>> handle(List<CheckResult> results) async {
    final outcomes = <InstallOutcome>[];
    final newVersions = <String>[];
    for (final r in results) {
      final s = r.source;
      if (r.newVersion != null) newVersions.add('${s.name} ${r.newVersion}');
      if (r.downloaded.isEmpty) continue;
      final files = r.downloaded.expand((d) => d.files).toList();
      var changed = false;

      // Android: learn the package id + version of the newest APK.
      final apks = files.where((f) => f.toLowerCase().endsWith('.apk')).toList();
      if (Platform.isAndroid && apks.isNotEmpty) {
        final info = await GetterxInstaller.apkInfo(apks.first);
        if (info != null) {
          s.packageId ??= info.packageName;
          s.apkVersionName = info.versionName;
          s.apkVersionCode = info.versionCode;
          changed = true;
        }
      }

      if (s.autoInstall && s.mode != TrackMode.trackOnly) {
        final candidates = Platform.isAndroid ? apks.take(1).toList() : files.where(isInstallable).take(1).toList();
        for (final f in candidates) {
          final o = await installFile(s, f);
          outcomes.add(o);
          s.installProblem = o.ok || o.needsUser ? null : o.message;
          changed = true;
        }
      }
      if (changed) await store.saveSource(s);
    }

    if (background) await _notify(outcomes, newVersions);
    return outcomes;
  }

  /// Installs one file for [s] (also used by the manual "Install" button).
  Future<InstallOutcome> installFile(TrackedSource s, String file) async {
    // Optional malware check (hash lookup only).
    final vt = VirusTotal(client, credentials.virustotalKey);
    if (vt.enabled) {
      final scan = await vt.check(File(file));
      await store.log(
        LogEntry(scan.verdict == ScanVerdict.flagged ? 'error' : 'info', '${s.name}: ${scan.summary}', sourceId: s.id),
      );
      if (scan.verdict == ScanVerdict.flagged) {
        return InstallOutcome(s, file, false, '${scan.summary}. Not installed. Details: ${scan.link}');
      }
    }

    if (Platform.isAndroid) {
      final apk = await GetterxInstaller.apkInfo(file);
      if (apk != null) {
        final installed = await GetterxInstaller.installedInfo(apk.packageName);
        if (installed != null &&
            installed.signatures.isNotEmpty &&
            apk.signatures.isNotEmpty &&
            installed.signatures.toSet().intersection(apk.signatures.toSet()).isEmpty) {
          return InstallOutcome(
            s,
            file,
            false,
            'Signature differs from the installed app (built by someone else or a different key). '
            'Uninstall the current app first if you trust this source.',
          );
        }
        if (installed != null && installed.versionCode > apk.versionCode) {
          return InstallOutcome(
            s,
            file,
            false,
            'The installed version (${installed.versionName}) is newer; downgrades are not installed automatically.',
          );
        }
      }
      final r = await GetterxInstaller.install(file);
      final ok = r.status == InstallStatus.success;
      await store.log(
        LogEntry(ok ? 'download' : 'error', '${s.name}: install ${r.status.name} ${r.message}', sourceId: s.id),
      );
      return switch (r.status) {
        InstallStatus.success => InstallOutcome(s, file, true, 'Installed'),
        InstallStatus.pendingUser => InstallOutcome(s, file, false, 'Tap to finish installing', needsUser: true),
        InstallStatus.noPermission => InstallOutcome(
          s,
          file,
          false,
          'Allow GetterX to install apps (Android settings)',
        ),
        InstallStatus.aborted => InstallOutcome(s, file, false, 'Install cancelled', needsUser: true),
        _ => InstallOutcome(s, file, false, 'Install failed: ${r.message}'),
      };
    }

    final r = await installDesktop(file, appName: s.name);
    await store.log(
      LogEntry(r.ok ? 'download' : 'error', '${s.name}: ${p.basename(file)}: ${r.message}', sourceId: s.id),
    );
    return InstallOutcome(s, file, r.ok, r.message);
  }

  Future<void> _notify(List<InstallOutcome> outcomes, List<String> newVersions) async {
    final settings = store.config.settings;
    final installed = outcomes.where((o) => o.ok).map((o) => o.source.name).toList();
    final needTap = outcomes.where((o) => o.needsUser).map((o) => o.source.name).toList();
    final failed = outcomes.where((o) => !o.ok && !o.needsUser).toList();
    if (installed.isNotEmpty) {
      await Notifier.show(
        'Updated ${installed.length} app${installed.length == 1 ? '' : 's'}',
        installed.join(', '),
        channel: 'installed',
      );
    }
    if (needTap.isNotEmpty) {
      await Notifier.show(
        'Updates ready to install',
        'Open GetterX to finish: ${needTap.join(', ')}',
        channel: 'attention',
      );
    }
    for (final f in failed) {
      await Notifier.show('${f.source.name}: not installed', f.message, channel: 'attention');
    }
    if (settings.notifyUpdates && newVersions.isNotEmpty) {
      await Notifier.show(
        '${newVersions.length} new version${newVersions.length == 1 ? '' : 's'}',
        newVersions.take(5).join(', ') + (newVersions.length > 5 ? ' …' : ''),
      );
    }
  }
}
