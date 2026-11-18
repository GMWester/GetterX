import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../credentials.dart';
import '../models.dart';
import 'source.dart';

/// itch.io games via the itch.io API (https://api.itch.io).
///
/// Needs an API key from https://itch.io/user/settings/api-keys. Free games
/// work with any key; paid games work if the key's account owns the game
/// (its download key is looked up automatically).
///
/// itch.io has no release history: uploads are replaced in place. Each check
/// produces one "release" that represents the current set of uploads; it gets
/// a new id whenever any upload changes (new build / new file), so "latest"
/// and "every new release" modes behave like they do for GitHub.
class ItchSource implements ReleaseSource {
  final http.Client client;
  final String apiKey;
  final String apiBase;

  ItchSource(this.client, {this.apiKey = '', this.apiBase = 'https://api.itch.io'});

  Map<String, String> get _headers =>
      mayReceiveCredential('itchio', Uri.parse(apiBase)) ? {'Authorization': 'Bearer $apiKey'} : const {};

  /// API URL with the key also given as `api_key` (accepted by every itch.io endpoint).
  Uri _api(String path, [Map<String, String> q = const {}]) {
    final u = Uri.parse('$apiBase$path');
    if (!mayReceiveCredential('itchio', u)) throw SourceException('Refusing to send itch.io key to ${u.host}');
    return u.replace(queryParameters: {...q, 'api_key': apiKey});
  }

  void _requireKey() {
    if (apiKey.isEmpty || !mayReceiveCredential('itchio', Uri.parse(apiBase))) {
      throw SourceException(
        'itch.io needs an API key: create one at itch.io/user/settings/api-keys and add it in Settings.',
      );
    }
  }

  /// ref is either a numeric game id or "author/game".
  Future<Map<String, dynamic>> _gameData(String ref) async {
    if (int.tryParse(ref) != null) {
      _requireKey();
      final j = await getJson(client, _api('/games/$ref'), headers: _headers) as Map<String, dynamic>;
      return (j['game'] as Map? ?? j).cast();
    }
    final parts = ref.split('/');
    if (parts.length != 2) throw SourceException('Invalid itch.io reference "$ref"');
    // Every game page exposes a small public JSON document with its id.
    final j =
        await getJson(client, Uri.parse('https://${parts[0]}.itch.io/${parts[1]}/data.json')) as Map<String, dynamic>;
    return {...j, 'url': 'https://${parts[0]}.itch.io/${parts[1]}'};
  }

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final g = await _gameData(ref);
    final cover = g['cover_image'] ?? g['cover_url'];
    return ProjectInfo(
      id: '${g['id']}',
      name: (g['title'] as String?) ?? ref,
      description: g['short_text'] as String?,
      iconUrl: cover is String ? cover : null,
      pageUrl: g['url'] as String?,
    );
  }

  Future<int?> _ownedDownloadKey(String gameId) async {
    for (var page = 1; page <= 50; page++) {
      final j =
          await getJson(client, _api('/profile/owned-keys', {'page': '$page'}), headers: _headers)
              as Map<String, dynamic>;
      final keys = (j['owned_keys'] as List? ?? const []).cast<Map>();
      for (final k in keys) {
        if ('${k['game_id']}' == gameId) return k['id'] as int?;
      }
      if (keys.isEmpty || keys.length < (j['per_page'] as int? ?? 50)) break;
    }
    return null;
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    _requireKey();
    final gameId = int.tryParse(source.ref) != null ? source.ref : '${(await _gameData(source.ref))['id']}';
    int? downloadKey;
    List<Map<String, dynamic>> uploads;
    try {
      uploads = await _uploads(gameId, null);
    } on SourceException {
      downloadKey = await _ownedDownloadKey(gameId);
      if (downloadKey == null) rethrow;
      uploads = await _uploads(gameId, downloadKey);
    }
    if (uploads.isEmpty) {
      // Paid games list nothing without the buyer's download key.
      downloadKey = await _ownedDownloadKey(gameId);
      if (downloadKey != null) uploads = await _uploads(gameId, downloadKey);
    }
    return [
      buildRelease(source.ref, uploads, apiBase: apiBase, apiKey: apiKey, downloadKeyId: downloadKey),
    ].whereType<RemoteRelease>().toList();
  }

  Future<List<Map<String, dynamic>>> _uploads(String gameId, int? downloadKey) async {
    final j =
        await getJson(
              client,
              _api('/games/$gameId/uploads', {if (downloadKey != null) 'download_key_id': '$downloadKey'}),
              headers: _headers,
            )
            as Map<String, dynamic>;
    if (j['errors'] != null) throw SourceException('itch.io: ${j['errors']}');
    return (j['uploads'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  static RemoteRelease? buildRelease(
    String ref,
    List<Map<String, dynamic>> uploads, {
    required String apiBase,
    required String apiKey,
    int? downloadKeyId,
  }) {
    if (uploads.isEmpty) return null;
    DateTime? newest;
    final sig = StringBuffer();
    final files = <RemoteFile>[];
    final sorted = [...uploads]..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
    for (final u in sorted) {
      final updated = DateTime.tryParse('${u['updated_at'] ?? u['created_at'] ?? ''}');
      if (updated != null && (newest == null || updated.isAfter(newest))) newest = updated;
      sig.write('${u['id']}:${u['build_id'] ?? ''}:${u['updated_at'] ?? ''}:${u['md5_hash'] ?? ''};');
      final traits = <String>{
        ...((u['traits'] as List?) ?? const []).map((e) => '$e'),
        for (final t in ['p_windows', 'p_linux', 'p_osx', 'p_android'])
          if (u[t] == true) t,
      };
      final platforms = <String>{
        if (traits.contains('p_windows')) 'windows',
        if (traits.contains('p_linux')) 'linux',
        if (traits.contains('p_osx')) 'macos',
        if (traits.contains('p_android')) 'android',
      };
      final q = {'api_key': apiKey, if (downloadKeyId != null) 'download_key_id': '$downloadKeyId'};
      final name = (u['filename'] as String?) ?? 'upload-${u['id']}';
      files.add(
        RemoteFile(
          name: name,
          urls: [Uri.parse('$apiBase/uploads/${u['id']}/download').replace(queryParameters: q).toString()],
          size: u['size'] as int?,
          hashes: {
            if (u['md5_hash'] is String && (u['md5_hash'] as String).isNotEmpty)
              'md5': (u['md5_hash'] as String).toLowerCase(),
          },
          platforms: platforms,
          // Demos / soundtracks are still "files"; filter with regex if unwanted.
          primary: u['type'] == null || u['type'] == 'default',
        ),
      );
    }
    final id = sha1.convert(utf8.encode(sig.toString())).toString().substring(0, 16);
    final date = newest ?? DateTime.now().toUtc();
    final version = '${date.year}-${_pad2(date.month)}-${_pad2(date.day)}_${_pad2(date.hour)}${_pad2(date.minute)}';
    return RemoteRelease(
      id: id,
      version: version,
      title: 'Build of $version',
      publishedAt: newest,
      channel: ReleaseChannel.release,
      files: files,
      pageUrl: ref.contains('/') ? 'https://${ref.split('/')[0]}.itch.io/${ref.split('/')[1]}' : null,
    );
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}
