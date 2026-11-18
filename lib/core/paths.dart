/// Where GetterX keeps its data, for the installed and the portable build.
///
/// Portable mode: if a file named `portable` or `portable.txt` (or a folder
/// `GetterX-Data`) sits next to the executable — or next to GetterX.app on
/// macOS — all settings live in `GetterX-Data` beside it and downloads
/// default to `GetterX-Downloads` beside it. Nothing is written elsewhere.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  final Directory dataDir;
  final String defaultDownloadRoot;
  final bool portable;

  /// Folder that holds the executable (or the .app bundle on macOS).
  final String installDir;
  const AppPaths(this.dataDir, this.defaultDownloadRoot, this.portable, this.installDir);
}

/// Directory that contains the program (the .app bundle's parent on macOS).
String installDirOf(String executable) {
  var dir = p.dirname(executable);
  if (Platform.isMacOS && dir.endsWith('.app/Contents/MacOS')) {
    dir = p.dirname(p.dirname(p.dirname(dir)));
  }
  return dir;
}

bool isPortableInstall(String installDir) =>
    File(p.join(installDir, 'portable')).existsSync() ||
    File(p.join(installDir, 'portable.txt')).existsSync() ||
    Directory(p.join(installDir, 'GetterX-Data')).existsSync();

String _home() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;

/// Desktop locations (also used by the CLI). Mobile callers pass their own.
AppPaths resolveDesktopPaths({String? executable, String? overrideDataDir}) {
  final exe = executable ?? Platform.resolvedExecutable;
  final install = installDirOf(exe);
  final env = Platform.environment['GETTERX_HOME'];
  if (overrideDataDir != null || (env != null && env.isNotEmpty)) {
    final d = overrideDataDir ?? env!;
    return AppPaths(Directory(d), p.join(d, 'Downloads'), false, install);
  }
  if (isPortableInstall(install)) {
    return AppPaths(Directory(p.join(install, 'GetterX-Data')), p.join(install, 'GetterX-Downloads'), true, install);
  }
  final home = _home();
  final String data;
  if (Platform.isWindows) {
    data = p.join(Platform.environment['APPDATA'] ?? p.join(home, 'AppData', 'Roaming'), 'GetterX');
  } else if (Platform.isMacOS) {
    data = p.join(home, 'Library', 'Application Support', 'GetterX');
  } else {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    data = p.join(xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.local', 'share'), 'getterx');
  }
  return AppPaths(Directory(data), p.join(home, 'Downloads', 'GetterX'), false, install);
}
