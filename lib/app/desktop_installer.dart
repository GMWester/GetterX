/// Installs downloaded desktop installers/packages without user interaction
/// where the format allows it. Only used for sources where the user turned on
/// "Install automatically".
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class DesktopInstallResult {
  final bool ok;
  final String message;
  const DesktopInstallResult(this.ok, this.message);
}

const _winTypes = ['.msi', '.exe', '.msix', '.msixbundle', '.appx', '.appxbundle'];
const _macTypes = ['.dmg', '.pkg', '.zip'];
const _linuxTypes = ['.appimage', '.deb', '.rpm', '.flatpak'];

/// Whether [file] is something GetterX can install on this OS.
bool isInstallable(String file) {
  final f = file.toLowerCase();
  final list = Platform.isWindows
      ? _winTypes
      : (Platform.isMacOS ? _macTypes : (Platform.isLinux ? _linuxTypes : const <String>[]));
  return list.any(f.endsWith);
}

Future<DesktopInstallResult> installDesktop(String path, {required String appName}) async {
  final f = path.toLowerCase();
  try {
    if (Platform.isWindows) return await _windows(path, f);
    if (Platform.isMacOS) return await _mac(path, f, appName);
    if (Platform.isLinux) return await _linux(path, f, appName);
  } catch (e) {
    return DesktopInstallResult(false, '$e');
  }
  return const DesktopInstallResult(false, 'Not supported on this system');
}

DesktopInstallResult _fromExit(ProcessResult r, String what, {List<int> okCodes = const [0]}) =>
    okCodes.contains(r.exitCode)
    ? DesktopInstallResult(true, '$what finished')
    : DesktopInstallResult(false, '$what failed (exit ${r.exitCode}) ${'${r.stderr}'.trim()}'.trim());

String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

Future<DesktopInstallResult> _windows(String path, String f) async {
  if (f.endsWith('.msi')) {
    final r = await Process.run('msiexec', ['/i', path, '/qn', '/norestart']);
    return _fromExit(r, 'MSI install', okCodes: const [0, 3010]);
  }
  if (f.endsWith('.msix') || f.endsWith('.msixbundle') || f.endsWith('.appx') || f.endsWith('.appxbundle')) {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Add-AppxPackage -Path ${_psQuote(path)}',
    ]);
    return _fromExit(r, 'App package install');
  }
  if (f.endsWith('.exe')) {
    final kind = await _exeKind(path);
    final args = switch (kind) {
      'inno' => ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
      'nsis' => ['/S'],
      'wix' => ['/quiet', '/norestart'],
      _ => null,
    };
    if (args == null) {
      // Unknown installer: start it normally so the user can click through.
      await Process.start(path, const [], mode: ProcessStartMode.detached);
      return const DesktopInstallResult(true, 'Installer opened (unknown type, cannot install silently)');
    }
    final r = await Process.run(path, args);
    return _fromExit(r, '${kind!.toUpperCase()} installer', okCodes: const [0, 3010]);
  }
  return const DesktopInstallResult(false, 'Unsupported file type');
}

/// Detects common installer frameworks from marker strings in the file.
Future<String?> _exeKind(String path) async {
  final raf = await File(path).open();
  try {
    final len = await raf.length();
    final head = await raf.read(len < 4 << 20 ? len : 4 << 20);
    final text = String.fromCharCodes(head.where((b) => b >= 32 && b < 127));
    if (text.contains('Inno Setup')) return 'inno';
    if (text.contains('Nullsoft') || text.contains('NSIS Error')) return 'nsis';
    if (text.contains('WixBundle') || text.contains('.wixburn')) return 'wix';
    return null;
  } finally {
    await raf.close();
  }
}

Future<String> _macTargetDir() async {
  const system = '/Applications';
  try {
    final probe = File(p.join(system, '.getterx-write-test'));
    await probe.writeAsString('x');
    await probe.delete();
    return system;
  } catch (_) {
    final user = p.join(Platform.environment['HOME']!, 'Applications');
    await Directory(user).create(recursive: true);
    return user;
  }
}

Future<DesktopInstallResult> _copyApp(Directory from) async {
  final apps = from.listSync().whereType<Directory>().where((d) => d.path.endsWith('.app')).toList();
  if (apps.isEmpty) return const DesktopInstallResult(false, 'No .app found');
  final target = await _macTargetDir();
  for (final app in apps) {
    final dest = p.join(target, p.basename(app.path));
    if (Directory(dest).existsSync()) await Directory(dest).delete(recursive: true);
    final r = await Process.run('ditto', [app.path, dest]);
    if (r.exitCode != 0) return _fromExit(r, 'Copy');
  }
  return DesktopInstallResult(true, 'Installed to $target');
}

Future<DesktopInstallResult> _mac(String path, String f, String appName) async {
  if (f.endsWith('.pkg')) {
    await Process.run('open', [path]); // macOS installer asks for the admin password itself
    return const DesktopInstallResult(true, 'Installer opened');
  }
  if (f.endsWith('.dmg')) {
    final mount = await Directory.systemTemp.createTemp('getterx-dmg');
    final a = await Process.run('hdiutil', [
      'attach',
      '-nobrowse',
      '-readonly',
      '-noautoopen',
      '-mountpoint',
      mount.path,
      path,
    ]);
    if (a.exitCode != 0) return _fromExit(a, 'Opening the disk image');
    try {
      final pkg = mount.listSync().where((e) => e.path.endsWith('.pkg')).firstOrNull;
      if (pkg != null && mount.listSync().every((e) => !e.path.endsWith('.app'))) {
        final copy = p.join(Directory.systemTemp.path, p.basename(pkg.path));
        await Process.run('ditto', [pkg.path, copy]);
        await Process.run('open', [copy]);
        return const DesktopInstallResult(true, 'Installer opened');
      }
      return await _copyApp(mount);
    } finally {
      await Process.run('hdiutil', ['detach', mount.path, '-quiet']);
    }
  }
  if (f.endsWith('.zip')) {
    final out = await Directory.systemTemp.createTemp('getterx-zip');
    final r = await Process.run('ditto', ['-x', '-k', path, out.path]);
    if (r.exitCode != 0) return _fromExit(r, 'Unzip');
    return _copyApp(out);
  }
  return const DesktopInstallResult(false, 'Unsupported file type');
}

Future<DesktopInstallResult> _linux(String path, String f, String appName) async {
  if (f.endsWith('.appimage')) {
    final dir = Directory(p.join(Platform.environment['HOME']!, 'Applications'));
    await dir.create(recursive: true);
    final safe = appName.replaceAll(RegExp(r'[^\w.-]+'), '-');
    final dest = File(p.join(dir.path, '$safe.AppImage'));
    final tmp = File('${dest.path}.new');
    await File(path).copy(tmp.path);
    await Process.run('chmod', ['+x', tmp.path]);
    await tmp.rename(dest.path);
    return DesktopInstallResult(true, 'Installed to ${dest.path}');
  }
  if (f.endsWith('.flatpak')) {
    final r = await Process.run('flatpak', ['install', '--user', '-y', '--noninteractive', path]);
    return _fromExit(r, 'Flatpak install');
  }
  if (f.endsWith('.deb')) {
    // pkexec shows the system password prompt.
    var r = await Process.run('pkexec', ['apt-get', 'install', '-y', path]);
    if (r.exitCode == 127 || r.exitCode == 126 && '${r.stderr}'.contains('apt-get')) {
      r = await Process.run('pkexec', ['dpkg', '-i', path]);
    }
    return _fromExit(r, '.deb install');
  }
  if (f.endsWith('.rpm')) {
    var r = await Process.run('pkexec', ['dnf', 'install', '-y', path]);
    if (r.exitCode == 127) r = await Process.run('pkexec', ['rpm', '-Uvh', path]);
    return _fromExit(r, '.rpm install');
  }
  return const DesktopInstallResult(false, 'Unsupported file type');
}
