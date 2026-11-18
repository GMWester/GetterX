import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// Codeberg and any Forgejo / Gitea instance. ref = "host/owner/repo".
class ForgejoSource implements ReleaseSource {
  final http.Client client;
  ForgejoSource(this.client);

  (String host, String repo) _split(String ref) {
    final parts = ref.split('/');
    if (parts.length < 3) throw SourceException('Expected host/owner/repo, got "$ref"');
    return (parts[0], '${parts[1]}/${parts[2]}');
  }

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final (host, repo) = _split(ref);
    final j = await getJson(client, Uri.https(host, '/api/v1/repos/$repo')) as Map<String, dynamic>;
    return ProjectInfo(
      id: '$host/${j['full_name'] ?? repo}',
      name: j['name'] as String? ?? repo,
      description: j['description'] as String?,
      pageUrl: j['html_url'] as String?,
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final (host, repo) = _split(source.ref);
    final out = <RemoteRelease>[];
    for (var page = 1; page < 200; page++) {
      final list = await getJson(
        client,
        Uri.https(host, '/api/v1/repos/$repo/releases', {'limit': '50', 'page': '$page'}),
      ) as List;
      for (final r in list.cast<Map<String, dynamic>>()) {
        if (r['draft'] == true) continue;
        final tag = r['tag_name'] as String? ?? '';
        out.add(
          RemoteRelease(
            id: '${r['id']}',
            version: tag,
            title: (r['name'] as String?)?.isNotEmpty == true ? r['name'] as String : tag,
            publishedAt: DateTime.tryParse('${r['published_at'] ?? r['created_at'] ?? ''}'),
            channel: r['prerelease'] == true ? ReleaseChannel.beta : ReleaseChannel.release,
            files: [
              for (final a in (r['assets'] as List? ?? const []).cast<Map<String, dynamic>>())
                RemoteFile(
                  name: a['name'] as String,
                  urls: [a['browser_download_url'] as String],
                  size: a['size'] as int?,
                ),
              if (source.includeSourceArchives && r['zipball_url'] is String)
                RemoteFile(
                  name: '${repo.split('/').last}-$tag-source.zip',
                  urls: [r['zipball_url'] as String],
                  isSourceArchive: true,
                ),
            ],
            pageUrl: r['html_url'] as String?,
            order: out.length,
          ),
        );
      }
      if (list.length < 50 || !full) break;
    }
    return out;
  }
}
