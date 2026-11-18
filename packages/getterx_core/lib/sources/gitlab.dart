import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// gitlab.com or a self-hosted GitLab. ref = "host/group[/subgroup]/project".
class GitLabSource implements ReleaseSource {
  final http.Client client;
  GitLabSource(this.client);

  (String host, String path) _split(String ref) {
    final i = ref.indexOf('/');
    if (i < 0) throw SourceException('Expected host/group/project, got "$ref"');
    return (ref.substring(0, i), ref.substring(i + 1));
  }

  Uri _api(String host, String path, String suffix, [Map<String, String>? q]) =>
      Uri.parse('https://$host/api/v4/projects/${Uri.encodeComponent(path)}$suffix').replace(queryParameters: q);

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final (host, path) = _split(ref);
    final j = await getJson(client, _api(host, path, '')) as Map<String, dynamic>;
    return ProjectInfo(
      id: '$host/${j['path_with_namespace'] ?? path}',
      name: j['name'] as String? ?? path,
      description: j['description'] as String?,
      pageUrl: j['web_url'] as String?,
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final (host, path) = _split(source.ref);
    final out = <RemoteRelease>[];
    for (var page = 1; page < 200; page++) {
      final list = await getJson(client, _api(host, path, '/releases', {'per_page': '100', 'page': '$page'})) as List;
      for (final r in list.cast<Map<String, dynamic>>()) {
        if (r['upcoming_release'] == true) continue;
        final tag = r['tag_name'] as String? ?? '';
        final assets = (r['assets'] as Map?) ?? const {};
        out.add(
          RemoteRelease(
            id: tag,
            version: tag,
            title: (r['name'] as String?)?.isNotEmpty == true ? r['name'] as String : tag,
            publishedAt: DateTime.tryParse('${r['released_at'] ?? r['created_at'] ?? ''}'),
            channel: ReleaseChannel.release,
            files: [
              for (final l in (assets['links'] as List? ?? const []).cast<Map>())
                RemoteFile(
                  name: _fileName(l['name'] as String?, (l['direct_asset_url'] ?? l['url']) as String),
                  urls: [(l['direct_asset_url'] ?? l['url']) as String],
                ),
              if (source.includeSourceArchives)
                for (final src in (assets['sources'] as List? ?? const []).cast<Map>())
                  if (src['format'] == 'zip')
                    RemoteFile(
                      name: '${path.split('/').last}-$tag-source.zip',
                      urls: [src['url'] as String],
                      isSourceArchive: true,
                    ),
            ],
            pageUrl: (r['_links'] as Map?)?['self'] as String?,
            order: out.length,
          ),
        );
      }
      if (list.length < 100 || !full) break;
    }
    return out;
  }

  static String _fileName(String? name, String url) {
    final last = Uri.tryParse(url)?.pathSegments.where((e) => e.isNotEmpty).lastOrNull;
    if (last != null && last.contains('.')) return Uri.decodeComponent(last);
    return name ?? last ?? 'download';
  }
}
