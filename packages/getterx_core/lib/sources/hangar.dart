import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// Hangar (hangar.papermc.io): Paper / Velocity / Waterfall plugins.
/// ref = project slug. Each platform build of a version is its own release so
/// "latest per platform & game version" works like mod loaders.
class HangarSource implements ReleaseSource {
  final http.Client client;
  final String api;
  HangarSource(this.client, {this.api = 'https://hangar.papermc.io/api/v1'});

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(client, Uri.parse('$api/projects/${Uri.encodeComponent(ref)}')) as Map;
    final ns = (j['namespace'] as Map?) ?? const {};
    return ProjectInfo(
      id: (j['name'] ?? ref) as String,
      name: (j['name'] ?? ref) as String,
      description: j['description'] as String?,
      iconUrl: j['avatarUrl'] as String?,
      pageUrl: 'https://hangar.papermc.io/${ns['owner'] ?? ''}/${ns['slug'] ?? ref}',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final all = <Map<String, dynamic>>[];
    for (var offset = 0; offset < 5000; offset += 25) {
      final j =
          await getJson(
                client,
                Uri.parse('$api/projects/${Uri.encodeComponent(source.ref)}/versions?limit=25&offset=$offset'),
              )
              as Map;
      final list = ((j['result'] as List?) ?? const []).cast<Map<String, dynamic>>();
      all.addAll(list);
      final count = ((j['pagination'] as Map?)?['count'] as int?) ?? 0;
      if (list.length < 25 || offset + 25 >= count || !full) break;
    }
    return parseVersions(all, source.ref);
  }

  static List<RemoteRelease> parseVersions(List<Map<String, dynamic>> versions, String slug) {
    final out = <RemoteRelease>[];
    for (final v in versions) {
      final name = v['name'] as String? ?? '';
      final channelName = (((v['channel'] as Map?)?['name']) as String? ?? 'Release').toLowerCase();
      final channel = channelName.contains('alpha')
          ? ReleaseChannel.alpha
          : (channelName == 'release' ? ReleaseChannel.release : ReleaseChannel.beta);
      final deps = (v['platformDependencies'] as Map?) ?? const {};
      final downloads = (v['downloads'] as Map?) ?? const {};
      for (final e in downloads.entries) {
        final platform = '${e.key}'.toLowerCase();
        final d = (e.value as Map?) ?? const {};
        final info = (d['fileInfo'] as Map?) ?? const {};
        final url = (d['downloadUrl'] ?? d['externalUrl']) as String?;
        if (url == null) continue;
        out.add(
          RemoteRelease(
            id: '$name@$platform',
            version: name,
            title: '$name ($platform)',
            publishedAt: DateTime.tryParse('${v['createdAt'] ?? ''}'),
            channel: channel,
            loaders: [platform],
            gameVersions: ((deps[e.key] as List?) ?? const []).map((x) => '$x').toList(),
            files: [
              RemoteFile(
                name: (info['name'] as String?) ?? '$slug-$name-$platform.jar',
                urls: [url],
                size: info['sizeBytes'] as int?,
                hashes: {if (info['sha256Hash'] is String) 'sha256': (info['sha256Hash'] as String).toLowerCase()},
                primary: true,
              ),
            ],
            pageUrl: 'https://hangar.papermc.io/$slug/versions/$name',
            order: out.length,
          ),
        );
      }
    }
    return out;
  }
}
