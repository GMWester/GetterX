import 'package:http/http.dart' as http;

import '../credentials.dart';
import '../models.dart';
import 'source.dart';

class ModrinthSource implements ReleaseSource {
  final http.Client client;
  final String apiBase;

  /// Personal access token: gives access to private / unlisted / draft projects.
  final String token;

  ModrinthSource(this.client, {this.token = '', this.apiBase = 'https://api.modrinth.com/v2'});

  Map<String, String> get _headers => {
        if (token.isNotEmpty && mayReceiveCredential('modrinth', Uri.parse(apiBase))) 'Authorization': token
      };

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(
            client, Uri.parse('$apiBase/project/${Uri.encodeComponent(ref)}'),
            headers: _headers)
        as Map<String, dynamic>;
    final type = j['project_type'] as String? ?? 'mod';
    return ProjectInfo(
      id: j['slug'] as String? ?? j['id'] as String,
      name: j['title'] as String? ?? ref,
      description: j['description'] as String?,
      iconUrl: j['icon_url'] as String?,
      pageUrl: 'https://modrinth.com/$type/${j['slug'] ?? j['id']}',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source,
      {bool full = true}) async {
    final list = await getJson(
        client,
        Uri.parse(
            '$apiBase/project/${Uri.encodeComponent(source.ref)}/version?include_changelog=false'),
        headers: _headers) as List;
    return parseVersions(list, source.ref);
  }

  static List<RemoteRelease> parseVersions(List list, String slug) {
    final out = <RemoteRelease>[];
    for (final v in list.cast<Map<String, dynamic>>()) {
      final files = (v['files'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .map((f) => RemoteFile(
                name: f['filename'] as String,
                urls: [f['url'] as String],
                size: f['size'] as int?,
                primary: f['primary'] == true,
                hashes: {
                  for (final e in ((f['hashes'] as Map?) ?? const {}).entries)
                    '${e.key}'.toLowerCase(): '${e.value}'.toLowerCase(),
                },
              ))
          .toList();
      // If no file is flagged primary, Modrinth treats the first as primary.
      if (files.isNotEmpty && !files.any((f) => f.primary)) {
        final f = files.first;
        files[0] = RemoteFile(
            name: f.name, urls: f.urls, size: f.size, hashes: f.hashes, primary: true);
      }
      out.add(RemoteRelease(
        id: v['id'] as String,
        version: v['version_number'] as String? ?? '',
        title: v['name'] as String? ?? v['version_number'] as String? ?? '',
        publishedAt: DateTime.tryParse(v['date_published'] as String? ?? ''),
        channel: switch (v['version_type']) {
          'beta' => ReleaseChannel.beta,
          'alpha' => ReleaseChannel.alpha,
          _ => ReleaseChannel.release,
        },
        loaders: (v['loaders'] as List? ?? const [])
            .map((e) => '$e'.toLowerCase())
            .toList(),
        gameVersions: (v['game_versions'] as List? ?? const []).cast<String>(),
        files: files,
        pageUrl: 'https://modrinth.com/project/$slug/version/${v['id']}',
        order: out.length,
      ));
    }
    return out;
  }
}
