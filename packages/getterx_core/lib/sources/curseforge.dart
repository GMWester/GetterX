import 'package:http/http.dart' as http;

import '../credentials.dart';
import '../models.dart';
import 'source.dart';

/// CurseForge for Minecraft (gameId 432).
///
/// The official API (https://api.curseforge.com) needs a free key from
/// https://console.curseforge.com. Without a key a compatible proxy base URL
/// can be configured in Settings.
class CurseForgeSource implements ReleaseSource {
  static const officialBase = 'https://api.curseforge.com';
  static const keylessProxyBase = 'https://api.curse.tools/v1/cf';
  static const minecraftGameId = 432;

  /// gameVersions entries that are loaders.
  static const loaderNames = {
    'forge': 'forge',
    'fabric': 'fabric',
    'neoforge': 'neoforge',
    'quilt': 'quilt',
    'liteloader': 'liteloader',
    'cauldron': 'cauldron',
    'rift': 'rift',
  };

  final http.Client client;
  final String apiKey;
  final String baseUrl;

  CurseForgeSource(this.client, {this.apiKey = '', String baseUrl = ''})
    : baseUrl = baseUrl.isNotEmpty
          ? baseUrl.replaceAll(RegExp(r'/+$'), '')
          : (apiKey.isNotEmpty ? officialBase : keylessProxyBase);

  /// The key is only ever sent to the official API host, never to a custom/proxy base URL.
  Map<String, String> get _headers => {
    if (apiKey.isNotEmpty && mayReceiveCredential('curseforge', Uri.parse(baseUrl))) 'x-api-key': apiKey,
  };

  Future<Map<String, dynamic>> _resolve(String ref) async {
    final id = int.tryParse(ref);
    if (id != null) {
      final j = await getJson(client, Uri.parse('$baseUrl/v1/mods/$id'), headers: _headers) as Map<String, dynamic>;
      return (j['data'] as Map).cast();
    }
    final j =
        await getJson(
              client,
              Uri.parse(
                '$baseUrl/v1/mods/search',
              ).replace(queryParameters: {'gameId': '$minecraftGameId', 'slug': ref}),
              headers: _headers,
            )
            as Map<String, dynamic>;
    final data = (j['data'] as List).cast<Map<String, dynamic>>();
    final match = data.where((m) => m['slug'] == ref).toList();
    if (match.isEmpty) throw SourceException('CurseForge project "$ref" not found');
    // Prefer mods (classId 6) if several classes share the slug.
    match.sort((a, b) => (a['classId'] == 6 ? 0 : 1) - (b['classId'] == 6 ? 0 : 1));
    return match.first;
  }

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final m = await _resolve(ref);
    return ProjectInfo(
      id: '${m['id']}',
      name: m['name'] as String? ?? ref,
      description: m['summary'] as String?,
      iconUrl: (m['logo'] as Map?)?['thumbnailUrl'] as String?,
      pageUrl: (m['links'] as Map?)?['websiteUrl'] as String?,
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final modId = int.tryParse(source.ref) ?? (await _resolve(source.ref))['id'];
    final out = <Map<String, dynamic>>[];
    const pageSize = 50;
    for (var index = 0; index < 10000; index += pageSize) {
      final j =
          await getJson(
                client,
                Uri.parse(
                  '$baseUrl/v1/mods/$modId/files',
                ).replace(queryParameters: {'index': '$index', 'pageSize': '$pageSize'}),
                headers: _headers,
              )
              as Map<String, dynamic>;
      final data = (j['data'] as List).cast<Map<String, dynamic>>();
      out.addAll(data);
      final total = (j['pagination'] as Map?)?['totalCount'] as int? ?? 0;
      if (data.length < pageSize || index + pageSize >= total) break;
    }
    return parseFiles(out, source.ref);
  }

  static List<RemoteRelease> parseFiles(List<Map<String, dynamic>> files, String ref) {
    final rel = <RemoteRelease>[];
    for (final f in files) {
      if (f['isAvailable'] == false) continue;
      final id = f['id'] as int;
      final fileName = f['fileName'] as String;
      final loaders = <String>[];
      final games = <String>[];
      for (final gv in (f['gameVersions'] as List? ?? const []).cast<String>()) {
        final l = loaderNames[gv.toLowerCase()];
        if (l != null) {
          loaders.add(l);
        } else if (RegExp(r'^\d+\.\d+').hasMatch(gv) || RegExp(r'^\d+w\d+[a-z]$').hasMatch(gv)) {
          games.add(gv);
        }
        // Skips "Client", "Server", "Java 21" etc.
      }
      final encoded = Uri.encodeComponent(fileName);
      final urls = <String>[
        if (f['downloadUrl'] is String) f['downloadUrl'] as String,
        // Fallback when the author disabled third-party distribution in the API.
        'https://mediafilez.forgecdn.net/files/${id ~/ 1000}/${id % 1000}/$encoded',
        'https://edge.forgecdn.net/files/${id ~/ 1000}/${id % 1000}/$encoded',
      ];
      final hashes = <String, String>{};
      for (final h in (f['hashes'] as List? ?? const []).cast<Map>()) {
        final algo = h['algo'] == 1 ? 'sha1' : (h['algo'] == 2 ? 'md5' : null);
        if (algo != null) hashes[algo] = '${h['value']}'.toLowerCase();
      }
      rel.add(
        RemoteRelease(
          id: '$id',
          version: f['displayName'] as String? ?? fileName,
          title: f['displayName'] as String? ?? fileName,
          publishedAt: DateTime.tryParse(f['fileDate'] as String? ?? ''),
          channel: switch (f['releaseType']) {
            2 => ReleaseChannel.beta,
            3 => ReleaseChannel.alpha,
            _ => ReleaseChannel.release,
          },
          loaders: loaders,
          gameVersions: games,
          files: [RemoteFile(name: fileName, urls: urls, size: f['fileLength'] as int?, hashes: hashes, primary: true)],
          pageUrl: null,
          order: rel.length,
        ),
      );
    }
    rel.sort((a, b) {
      final c = (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0));
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return rel;
  }
}
