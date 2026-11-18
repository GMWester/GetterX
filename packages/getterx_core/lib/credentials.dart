/// Secrets for the sources. Never written to config.json or the log.
///
/// The app keeps them in the OS credential store (see lib/app/secure_credentials.dart);
/// the CLI reads them from environment variables.
library;

import 'dart:io';

class Credentials {
  final String githubToken;
  final String curseforgeApiKey;
  final String itchApiKey;
  final String modrinthToken;

  /// Optional: checks downloaded installers against VirusTotal before auto-install.
  final String virustotalKey;

  const Credentials({
    this.githubToken = '',
    this.curseforgeApiKey = '',
    this.itchApiKey = '',
    this.modrinthToken = '',
    this.virustotalKey = '',
  });

  static const keys = ['githubToken', 'curseforgeApiKey', 'itchApiKey', 'modrinthToken', 'virustotalKey'];

  Map<String, String> toMap() => {
    'githubToken': githubToken,
    'curseforgeApiKey': curseforgeApiKey,
    'itchApiKey': itchApiKey,
    'modrinthToken': modrinthToken,
    'virustotalKey': virustotalKey,
  };

  factory Credentials.fromMap(Map<String, String?> m) => Credentials(
    githubToken: (m['githubToken'] ?? '').trim(),
    curseforgeApiKey: (m['curseforgeApiKey'] ?? '').trim(),
    itchApiKey: (m['itchApiKey'] ?? '').trim(),
    modrinthToken: (m['modrinthToken'] ?? '').trim(),
    virustotalKey: (m['virustotalKey'] ?? '').trim(),
  );

  Credentials copyWith({
    String? githubToken,
    String? curseforgeApiKey,
    String? itchApiKey,
    String? modrinthToken,
    String? virustotalKey,
  }) => Credentials(
    githubToken: githubToken ?? this.githubToken,
    curseforgeApiKey: curseforgeApiKey ?? this.curseforgeApiKey,
    itchApiKey: itchApiKey ?? this.itchApiKey,
    modrinthToken: modrinthToken ?? this.modrinthToken,
    virustotalKey: virustotalKey ?? this.virustotalKey,
  );

  /// All non-empty secret values (used for redaction).
  Iterable<String> get values => toMap().values.where((v) => v.length >= 4);

  /// CLI: GETTERX_GITHUB_TOKEN, GETTERX_CURSEFORGE_KEY, GETTERX_ITCH_KEY,
  /// GETTERX_MODRINTH_TOKEN, GETTERX_VIRUSTOTAL_KEY.
  factory Credentials.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    return Credentials(
      githubToken: e['GETTERX_GITHUB_TOKEN'] ?? e['GITHUB_TOKEN'] ?? '',
      curseforgeApiKey: e['GETTERX_CURSEFORGE_KEY'] ?? '',
      itchApiKey: e['GETTERX_ITCH_KEY'] ?? '',
      modrinthToken: e['GETTERX_MODRINTH_TOKEN'] ?? '',
      virustotalKey: e['GETTERX_VIRUSTOTAL_KEY'] ?? '',
    );
  }
}

abstract class CredentialStore {
  Future<Credentials> read();
  Future<void> write(Credentials c);
}

class EnvCredentialStore implements CredentialStore {
  @override
  Future<Credentials> read() async => Credentials.fromEnvironment();
  @override
  Future<void> write(Credentials c) async =>
      throw UnsupportedError('Set GETTERX_* environment variables to give the CLI credentials.');
}

// ---------------------------------------------------------------------------
// Security helpers

/// Hosts each credential may ever be sent to (exact match, HTTPS only).
const credentialHosts = <String, Set<String>>{
  'github': {'api.github.com', 'github.com'},
  'curseforge': {'api.curseforge.com'},
  'itchio': {'api.itch.io'},
  'modrinth': {'api.modrinth.com'},
  'virustotal': {'www.virustotal.com'},
};

bool mayReceiveCredential(String service, Uri uri) =>
    uri.scheme == 'https' && (credentialHosts[service]?.contains(uri.host.toLowerCase()) ?? false);

final _secretParam = RegExp(
  r'((?:api_key|apikey|access_token|token|key|password|client_secret|download_key_id)=)[^&\s#]+',
  caseSensitive: false,
);
final _bearer = RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final _ghToken = RegExp(r'\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b');

/// Known secrets, filled by the app/CLI after loading credentials.
final redactionValues = <String>{};

/// Removes secrets from text that may be shown, logged or reported.
String redact(String text) {
  var out = text
      .replaceAllMapped(_secretParam, (m) => '${m[1]}***')
      .replaceAllMapped(_bearer, (m) => '${m[1]}***')
      .replaceAll(_ghToken, '***');
  for (final v in redactionValues) {
    if (v.length >= 4) out = out.replaceAll(v, '***');
  }
  return out;
}
