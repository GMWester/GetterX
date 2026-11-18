/// Android-only helpers: install APKs (silent updates on Android 12+),
/// installed versions, APK metadata, signatures and device apps.
library;

import 'dart:io';

import 'package:flutter/services.dart';

enum InstallStatus { success, pendingUser, aborted, failure, noPermission, unsupported }

class InstallResult {
  final InstallStatus status;
  final String message;
  const InstallResult(this.status, [this.message = '']);
  bool get ok => status == InstallStatus.success;
  @override
  String toString() => '${status.name}${message.isEmpty ? '' : ': $message'}';
}

class AppPackageInfo {
  final String packageName;
  final String? versionName;
  final int versionCode;
  final String? label;
  final List<String> signatures;
  final bool installedByUs;
  final bool system;
  const AppPackageInfo({
    required this.packageName,
    this.versionName,
    this.versionCode = 0,
    this.label,
    this.signatures = const [],
    this.installedByUs = false,
    this.system = false,
  });

  factory AppPackageInfo.fromMap(Map m) => AppPackageInfo(
    packageName: m['packageName'] as String,
    versionName: m['versionName'] as String?,
    versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
    label: m['label'] as String?,
    signatures: ((m['signatures'] as List?) ?? const []).cast<String>(),
    installedByUs: m['installedByUs'] == true,
    system: m['system'] == true,
  );
}

class GetterxInstaller {
  static const _ch = MethodChannel('getterx/installer');
  static bool get supported => Platform.isAndroid;

  static Future<bool> canInstall() async => supported && (await _ch.invokeMethod<bool>('canInstall') ?? false);

  static Future<void> openInstallPermissionSettings() => _ch.invokeMethod('openInstallPermissionSettings');

  static Future<InstallResult> install(String apkPath) async {
    if (!supported) return const InstallResult(InstallStatus.unsupported);
    final r = Map<String, dynamic>.from(await _ch.invokeMethod<Map>('install', {'path': apkPath}) ?? const {});
    final msg = (r['message'] as String?) ?? '';
    return switch (r['status']) {
      'success' => InstallResult(InstallStatus.success, msg),
      'pending_user' => InstallResult(InstallStatus.pendingUser, msg),
      'aborted' => InstallResult(InstallStatus.aborted, msg),
      'no_permission' => InstallResult(InstallStatus.noPermission, msg),
      _ => InstallResult(InstallStatus.failure, msg),
    };
  }

  static Future<AppPackageInfo?> apkInfo(String apkPath) async {
    if (!supported) return null;
    final m = await _ch.invokeMethod<Map>('apkInfo', {'path': apkPath});
    return m == null ? null : AppPackageInfo.fromMap(m);
  }

  static Future<AppPackageInfo?> installedInfo(String packageName) async {
    if (!supported) return null;
    final m = await _ch.invokeMethod<Map>('installedInfo', {'packageName': packageName});
    return m == null ? null : AppPackageInfo.fromMap(m);
  }

  static Future<List<AppPackageInfo>> installedApps({bool includeSystem = false}) async {
    if (!supported) return const [];
    final l = await _ch.invokeMethod<List>('installedApps', {'includeSystem': includeSystem}) ?? const [];
    return l.map((e) => AppPackageInfo.fromMap(e as Map)).toList();
  }

  static Future<bool> launch(String packageName) async =>
      supported && (await _ch.invokeMethod<bool>('launch', {'packageName': packageName}) ?? false);

  static Future<void> appInfo(String packageName) => _ch.invokeMethod('appInfo', {'packageName': packageName});

  static Future<void> uninstall(String packageName) => _ch.invokeMethod('uninstall', {'packageName': packageName});
}
