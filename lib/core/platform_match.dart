/// Picks release assets suited to an operating system / CPU.
library;

import 'dart:io' show Platform;

class PlatformInfo {
  /// android, ios, windows, macos, linux
  final String os;

  /// arm64, x64, arm, x86, riscv64
  final String arch;
  const PlatformInfo(this.os, this.arch);

  static PlatformInfo current() {
    final m = RegExp(r'on "(\w+)_(\w+)"').firstMatch(Platform.version);
    var arch = m?.group(2) ?? 'x64';
    if (arch == 'ia32') arch = 'x86';
    return PlatformInfo(Platform.operatingSystem, arch);
  }
}

const _osExt = <String, List<String>>{
  'android': ['.apk'],
  'ios': ['.ipa'],
  'windows': ['.exe', '.msi', '.msix', '.msixbundle', '.appx', '.zip', '.7z'],
  'macos': ['.dmg', '.pkg', '.zip', '.tar.gz'],
  'linux': ['.appimage', '.deb', '.rpm', '.flatpak', '.snap', '.tar.gz', '.tar.xz', '.tar.zst', '.zip'],
};

/// Extensions that unambiguously belong to one OS (no keyword needed).
const _uniqueExt = <String, List<String>>{
  'android': ['.apk'],
  'ios': ['.ipa'],
  'windows': ['.exe', '.msi', '.msix', '.msixbundle', '.appx'],
  'macos': ['.dmg', '.pkg'],
  'linux': ['.appimage', '.deb', '.rpm', '.flatpak', '.snap'],
};

const _osWords = <String, List<String>>{
  'android': ['android'],
  'ios': ['ios', 'iphone'],
  'windows': ['windows', 'win64', 'win32', 'win'],
  'macos': ['macos', 'mac', 'darwin', 'osx', 'apple', 'universal'],
  'linux': ['linux'],
};

const _archWords = <String, List<String>>{
  'arm64': ['arm64', 'aarch64', 'arm64-v8a', 'armv8'],
  'x64': ['x64', 'x86_64', 'x86-64', 'amd64', 'win64'],
  'arm': ['armeabi-v7a', 'armeabi', 'armv7', 'armv7l', 'armhf', 'arm32'],
  'x86': ['x86', 'i386', 'i686', 'win32', '386'],
  'riscv64': ['riscv64'],
};

const _junkExt = ['.sha256', '.sha256sum', '.sha512', '.sha1', '.md5', '.sig', '.asc', '.minisig', '.pem', '.sbom', '.spdx', '.json', '.txt', '.blockmap', '.yml', '.yaml'];

List<String> _tokens(String name) =>
    name.toLowerCase().split(RegExp(r'[^a-z0-9_]+|_(?![0-9])')).where((t) => t.isNotEmpty).toList();

bool _hasWord(String lower, List<String> tokens, String w) {
  if (w.contains('-') || w.contains('_')) return lower.contains(w);
  return tokens.contains(w);
}

String? _archOf(String name) {
  final lower = name.toLowerCase();
  final toks = _tokens(name);
  // Check specific (longer) words first so x86_64 is not read as x86.
  for (final arch in ['arm64', 'x64', 'arm', 'riscv64', 'x86']) {
    if (_archWords[arch]!.any((w) => _hasWord(lower, toks, w))) return arch;
  }
  return null;
}

bool _isOtherOs(String lower, List<String> toks, String os) {
  for (final e in _osWords.entries) {
    if (e.key == os) continue;
    // "universal" is used by macOS and Android bundles alike; ignore for exclusion.
    if (e.value.where((w) => w != 'universal').any((w) => _hasWord(lower, toks, w))) {
      if (!_osWords[os]!.any((w) => _hasWord(lower, toks, w))) return true;
    }
  }
  return false;
}

/// Returns the subset of [names] suited to [p]. Never returns junk files.
List<String> pickPlatformFiles(List<String> names, PlatformInfo p) {
  final exts = _osExt[p.os] ?? const [];
  final unique = _uniqueExt[p.os] ?? const [];
  final matches = <String>[];
  for (final n in names) {
    final lower = n.toLowerCase();
    if (_junkExt.any(lower.endsWith)) continue;
    final ext = exts.where(lower.endsWith).toList();
    if (ext.isEmpty) continue;
    final toks = _tokens(n);
    final isUnique = unique.any(lower.endsWith);
    if (!isUnique && !_osWords[p.os]!.any((w) => _hasWord(lower, toks, w))) continue;
    if (_isOtherOs(lower, toks, p.os)) continue;
    final arch = _archOf(n);
    if (arch != null && arch != p.arch) {
      // Apple Silicon can run x64 builds, but only if there is no native one.
      if (!(p.os == 'macos' && p.arch == 'arm64' && arch == 'x64')) continue;
    }
    matches.add(n);
  }
  // Prefer builds made for this exact CPU over universal / emulated ones.
  final native = matches.where((n) => _archOf(n) == p.arch).toList();
  if (p.os == 'android' && native.isNotEmpty) return native;
  if (p.os == 'macos' && p.arch == 'arm64') {
    final noX64 = matches.where((n) => _archOf(n) != 'x64').toList();
    if (noX64.isNotEmpty) return noX64;
  }
  return matches;
}
