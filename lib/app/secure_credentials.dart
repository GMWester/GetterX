import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:getterx_core/credentials.dart';

/// Stores tokens / API keys in the operating system's credential store:
/// Android Keystore, iOS/macOS Keychain, Windows Credential Manager (DPAPI),
/// Linux Secret Service (libsecret). Never in plain files.
class SecureCredentialStore implements CredentialStore {
  static const _prefix = 'getterx.';

  final FlutterSecureStorage _s = const FlutterSecureStorage(
    // Android: encrypted with a Keystore-backed key; data excluded from backups via manifest.
    aOptions: AndroidOptions(),
    // first_unlock_this_device: readable by background checks after the first
    // unlock, never synced to iCloud or migrated to another device.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    // The legacy login keychain works for unsigned / ad-hoc signed builds.
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

  @override
  Future<Credentials> read() async {
    final m = <String, String?>{};
    for (final k in Credentials.keys) {
      m[k] = await _s.read(key: '$_prefix$k');
    }
    return Credentials.fromMap(m);
  }

  @override
  Future<void> write(Credentials c) async {
    for (final e in c.toMap().entries) {
      if (e.value.isEmpty) {
        await _s.delete(key: '$_prefix${e.key}');
      } else {
        await _s.write(key: '$_prefix${e.key}', value: e.value);
      }
    }
  }
}
