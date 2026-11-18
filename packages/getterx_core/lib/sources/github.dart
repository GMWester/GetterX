import 'package:http/http.dart' as http;

import '../credentials.dart';
import '../models.dart';
import 'source.dart';

class GitHubSource implements ReleaseSource {
  final http.Client client;
  final String token;
  final String apiBase;

  GitHubSource(this.client, {this.token = '', this.apiBase = 'https://api.github.com'});

  Map<String, String> get _headers => {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    if (_tokenAllowed) 'Authorization': 'Bearer $token',
  };

  bool get _tokenAllowed => token.isNotEmpty && mayReceiveCredential('github', Uri.parse(apiBase));

  /// Auth headers for a download URL, only if it points at GitHub's API host.
  Map<String, String> _authFor(Object? url) =>
      _tokenAllowed && url is String && mayReceiveCredential('github', Uri.parse(url)) ? _assetHeaders : const {};

  Map<String, String> get _assetHeaders => {'Accept': 'application/octet-stream', 'Authorization': 'Bearer $token'};

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(client, Uri.parse('$apiBase/repos/$ref'), headers: _headers) as Map<String, dynamic>;
    return ProjectInfo(
      id: j['full_name'] as String,
      name: j['name'] as String,
      description: j['description'] as String?,
      iconUrl: (j['owner'] as Map?)?['avatar_url'] as String?,
      pageUrl: j['html_url'] as String?,
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final out = <RemoteRelease>[];
    final repoName = source.ref.split('/').last;
    for (var page = 1; ; page++) {
      final list =
          await getJson(
                client,
                Uri.parse('$apiBase/repos/${source.ref}/releases?per_page=100&page=$page'),
                headers: _headers,
              )
              as List;
      for (final r in list.cast<Map<String, dynamic>>()) {
        if (r['draft'] == true) continue;
        final tag = (r['tag_name'] as String?) ?? '';
        final files = <RemoteFile>[
          for (final a in (r['assets'] as List? ?? const []).cast<Map<String, dynamic>>())
            RemoteFile(
              name: a['name'] as String,
              // With a token the API URL is used so private repos work; it
              // redirects to a signed URL (auth is dropped on the redirect).
              urls: [if (_authFor(a['url']).isNotEmpty) a['url'] as String, a['browser_download_url'] as String],
              headers: _authFor(a['url']),
              size: a['size'] as int?,
              hashes: _digest(a['digest'] as String?),
            ),
          if (source.includeSourceArchives && r['zipball_url'] != null)
            RemoteFile(
              name: '$repoName-${_safeTag(tag)}-source.zip',
              urls: [r['zipball_url'] as String],
              headers: _authFor(r['zipball_url']),
              isSourceArchive: true,
            ),
        ];
        out.add(
          RemoteRelease(
            id: '${r['id']}',
            version: tag,
            title: (r['name'] as String?)?.trim().isNotEmpty == true ? r['name'] as String : tag,
            publishedAt: DateTime.tryParse((r['published_at'] ?? r['created_at'] ?? '') as String),
            channel: r['prerelease'] == true ? ReleaseChannel.beta : ReleaseChannel.release,
            files: files,
            pageUrl: r['html_url'] as String?,
            order: out.length,
          ),
        );
      }
      if (list.length < 100 || !full) break;
    }
    if (out.isEmpty && source.tagsFallback) {
      return _fetchTags(source, repoName, full: full);
    }
    return out;
  }

  Future<List<RemoteRelease>> _fetchTags(TrackedSource source, String repoName, {required bool full}) async {
    final out = <RemoteRelease>[];
    for (var page = 1; ; page++) {
      final list =
          await getJson(
                client,
                Uri.parse('$apiBase/repos/${source.ref}/tags?per_page=100&page=$page'),
                headers: _headers,
              )
              as List;
      for (final t in list.cast<Map<String, dynamic>>()) {
        final name = t['name'] as String;
        out.add(
          RemoteRelease(
            id: 'tag:$name',
            version: name,
            title: name,
            // The tags API has no dates; order (newest first by GitHub's sort) is used.
            publishedAt: null,
            channel: ReleaseChannel.release,
            files: [
              RemoteFile(
                name: '$repoName-${_safeTag(name)}-source.zip',
                urls: [t['zipball_url'] as String],
                headers: _authFor(t['zipball_url']),
                isSourceArchive: true,
              ),
            ],
            pageUrl: 'https://github.com/${source.ref}/releases/tag/$name',
            order: out.length,
          ),
        );
      }
      if (list.length < 100 || !full) break;
    }
    return out;
  }

  static Map<String, String> _digest(String? d) {
    if (d == null || !d.contains(':')) return const {};
    final i = d.indexOf(':');
    return {d.substring(0, i).toLowerCase(): d.substring(i + 1).toLowerCase()};
  }

  static String _safeTag(String t) => t.replaceAll(RegExp(r'[^\w.\-+]'), '_');
}
