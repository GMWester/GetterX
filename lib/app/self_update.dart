/// GetterX updating itself from its own GitHub releases.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'package:getterx_core/downloader.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/paths.dart';
import 'package:getterx_core/platform_match.dart';
import 'package:getterx_core/sources/github.dart';
import 'package:getterx_core/sources/source.dart';
import 'package:getterx_core/version_utils.dart';

/// The only repository GetterX ever updates itself from.
const selfRepo = 'gmwester/GetterX';

enum InstallKind {
  android,
  ios,
  windowsInstalled,
  windowsPortable,
  linuxAppImage,
  linuxPackage,
  linuxFolder,
  macApp,
  unknown,
}

class AppUpdate {
  final String version;
  final RemoteRelease release;
  final RemoteFile? asset;
  const AppUpdate(this.version, this.release, this.asset);
}

InstallKind detectInstallKind() {
  if (Platform.isAndroid) return InstallKind.android;
  if (Platform.isIOS) return InstallKind.ios;
  final install = installDirOf(Platform.resolvedExecutable);
  if (Platform.isWindows) {
    return isPortableInstall(install) ? InstallKind.windowsPortable : InstallKind.windowsInstalled;
  }
  if (Platform.isMacOS) return InstallKind.macApp;
  if (Platform.isLinux) {
    if ((Platform.environment['APPIMAGE'] ?? '').isNotEmpty) return InstallKind.linuxAppImage;
    if (install.startsWith('/usr/') || install.startsWith('/opt/getterx')) return InstallKind.linuxPackage;
    return InstallKind.linuxFolder;
  }
  return InstallKind.unknown;
}

String installKindLabel(InstallKind k) => switch (k) {
  InstallKind.windowsInstalled => 'Installed',
  InstallKind.windowsPortable || InstallKind.linuxFolder => 'Portable / folder',
  InstallKind.linuxAppImage => 'AppImage',
  InstallKind.linuxPackage => 'System package (.deb)',
  InstallKind.macApp => 'App bundle',
  InstallKind.android => 'Android app',
  InstallKind.ios => 'iOS app',
  InstallKind.unknown => 'Unknown',
};

/// Release asset expected for this install (names produced by CI).
String? expectedAssetName(InstallKind k, PlatformInfo pl) => switch (k) {
  InstallKind.android =>
    'GetterX-android-${switch (pl.arch) {
      'arm64' => 'arm64-v8a',
      'arm' => 'armeabi-v7a',
      'x64' => 'x86_64',
      _ => 'universal',
    }}.apk',
  InstallKind.windowsInstalled => 'GetterX-windows-x64-setup.exe',
  InstallKind.windowsPortable => 'GetterX-windows-x64-portable.zip',
  InstallKind.linuxAppImage => 'GetterX-linux-x64.AppImage',
  InstallKind.linuxPackage => 'GetterX-linux-x64.deb',
  InstallKind.linuxFolder => 'GetterX-linux-x64-portable.tar.gz',
  InstallKind.macApp => 'GetterX-macos.zip',
  InstallKind.ios || InstallKind.unknown => null,
};

class SelfUpdater {
  final http.Client client;
  SelfUpdater(this.client);

  Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Returns the newer release, or null when up to date.
  Future<AppUpdate?> check() async {
    final src = GitHubSource(client); // anonymous: never uses the user's token
    final rels = await src.fetchReleases(
      TrackedSource(id: 'self', kind: SourceKind.github, ref: selfRepo, name: 'GetterX', tagsFallback: false),
      full: false,
    );
    final stable = rels.where((r) => r.channel == ReleaseChannel.release).toList();
    if (stable.isEmpty) return null;
    final latest = stable.first;
    final latestV = latest.version.replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    if (compareVersions(latestV, await currentVersion()) <= 0) return null;
    final kind = detectInstallKind();
    final want = expectedAssetName(kind, PlatformInfo.current());
    RemoteFile? asset;
    for (final f in latest.files) {
      if (f.name == want) asset = f;
    }
    if (asset == null && kind == InstallKind.android) {
      asset = latest.files.where((f) => f.name == 'GetterX-android-universal.apk').firstOrNull;
    }
    return AppUpdate(latestV, latest, asset);
  }

  /// Downloads and installs [u]. On desktop this exits the app and an
  /// external helper replaces the files and restarts GetterX.
  Future<void> install(AppUpdate u, {void Function(double?)? onProgress}) async {
    final kind = detectInstallKind();
    final asset = u.asset;
    if (kind == InstallKind.ios || asset == null) {
      await launchUrl(
        Uri.parse(u.release.pageUrl ?? 'https://github.com/$selfRepo/releases/latest'),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    // Integrity: the asset must carry GitHub's SHA-256 digest; the
    // downloader verifies it before the file is used.
    if (!asset.hashes.containsKey('sha256')) {
      throw SourceException('The update has no published checksum; refusing to install it.');
    }
    final tmp = await Directory.systemTemp.createTemp('getterx-update');
    final file = File(p.join(tmp.path, asset.name));
    await Downloader(client)
        .download(asset, file, onProgress: (r, t) => onProgress?.call(t == null || t == 0 ? null : r / t));

    final installDir = installDirOf(Platform.resolvedExecutable);
    final exe = Platform.resolvedExecutable;
    switch (kind) {
      case InstallKind.android:
        await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
        return;
      case InstallKind.windowsInstalled:
        final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
        await Process.start(file.path, [
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/RELAUNCH=1',
          p.isWithin(pf, installDir) ? '/ALLUSERS' : '/CURRENTUSER',
          '/DIR=$installDir',
        ], mode: ProcessStartMode.detached);
        exit(0);
      case InstallKind.windowsPortable:
        String c(String v) => v.replaceAll('%', '%%'); // no variable expansion in paths
        final script = File(p.join(tmp.path, 'update.cmd'));
        await script.writeAsString(
          [
            '@echo off',
            ':wait',
            'tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul && (timeout /t 1 /nobreak >nul & goto wait)',
            'mkdir "${c(tmp.path)}\\x"',
            'tar -xf "${c(file.path)}" -C "${c(tmp.path)}\\x"',
            'robocopy "${c(tmp.path)}\\x\\GetterX" "${c(installDir)}" /E /XD GetterX-Data GetterX-Downloads /NFL /NDL /NJH /NJS /NP',
            'start "" "${c(exe)}"',
          ].join('\r\n'),
        );
        await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
        exit(0);
      case InstallKind.linuxAppImage:
        final target = Platform.environment['APPIMAGE']!;
        final staged = File('$target.new');
        await file.copy(staged.path);
        await Process.run('chmod', ['+x', staged.path]);
        await staged.rename(target); // replacing a running AppImage is safe on Linux
        await Process.start(target, [], mode: ProcessStartMode.detached);
        exit(0);
      case InstallKind.linuxPackage:
        await OpenFilex.open(file.path); // hands the .deb to the system package installer
        return;
      case InstallKind.linuxFolder:
        await _runShell(tmp.path, [
          'while kill -0 $pid 2>/dev/null; do sleep 1; done',
          'mkdir -p ${q('${tmp.path}/x')} && tar -xzf ${q(file.path)} -C ${q('${tmp.path}/x')}',
            // Keep the current mode: only a portable install keeps portable.txt.
            '[ -f ${q('$installDir/portable.txt')} ] || rm -f ${q('${tmp.path}/x/GetterX/portable.txt')}',
          'cp -a ${q('${tmp.path}/x/GetterX/.')} ${q('$installDir/')}',
          'nohup ${q(exe)} >/dev/null 2>&1 &',
        ]);
        exit(0);
      case InstallKind.macApp:
        final bundle = p.dirname(p.dirname(p.dirname(exe))); // …/GetterX.app
        if (!bundle.endsWith('.app') || p.split(bundle).length < 3) {
          throw SourceException('Unexpected app location $bundle; update manually.');
        }
        await _runShell(tmp.path, [
          'while kill -0 $pid 2>/dev/null; do sleep 1; done',
          'mkdir -p ${q('${tmp.path}/x')} && ditto -x -k ${q(file.path)} ${q('${tmp.path}/x')}',
          'rm -rf ${q(bundle)} && ditto ${q('${tmp.path}/x/GetterX.app')} ${q(bundle)}',
          'open ${q(bundle)}',
        ]);
        exit(0);
      case InstallKind.ios:
      case InstallKind.unknown:
        return;
    }
  }

  /// Quotes a value for /bin/sh so paths with spaces, quotes or `$` are safe.
  static String q(String v) => "'${v.replaceAll("'", r"'\''")}'";

  Future<void> _runShell(String dir, List<String> lines) async {
    final script = File(p.join(dir, 'update.sh'));
    await script.writeAsString('#!/bin/sh\nset -e\n${lines.join('\n')}\n');
    await Process.run('chmod', ['+x', script.path]);
    await Process.start('/bin/sh', [script.path], mode: ProcessStartMode.detached);
  }
}
