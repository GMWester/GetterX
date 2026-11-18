/// Search several sources at once (mods, modpacks, resource packs, shaders,
/// data packs, plugins, repositories, game mods).
library;

import 'package:http/http.dart' as http;

import 'credentials.dart';
import 'models.dart';
import 'sources/curseforge.dart';
import 'sources/source.dart';

enum ContentType { any, mod, modpack, resourcepack, shader, datapack, plugin, repository }

String contentTypeLabel(ContentType t) => switch (t) {
  ContentType.any => 'Anything',
  ContentType.mod => 'Mods',
  ContentType.modpack => 'Modpacks',
  ContentType.resourcepack => 'Resource packs',
  ContentType.shader => 'Shaders',
  ContentType.datapack => 'Data packs',
  ContentType.plugin => 'Plugins',
  ContentType.repository => 'Repositories / apps',
};

class SearchResult {
  final SourceKind kind;

  /// A link or "kind:ref" accepted by parseSourceLink / Engine.createFromLink.
  final String link;
  final String title;
  final String? description;
  final String? author;
  final String? iconUrl;
  final int? downloads;
  final String? type;
  final DateTime? updated;
  const SearchResult({
    required this.kind,
    required this.link,
    required this.title,
    this.description,
    this.author,
    this.iconUrl,
    this.downloads,
    this.type,
    this.updated,
  });
}

class SearchOutcome {
  final List<SearchResult> results;

  /// Sources that failed (shown as a hint, never fatal).
  final Map<SourceKind, String> errors;
  const SearchOutcome(this.results, this.errors);
}

/// Sources that can be searched, and which content types each supports.
const searchableKinds = <SourceKind, Set<ContentType>>{
  SourceKind.modrinth: {
    ContentType.mod,
    ContentType.modpack,
    ContentType.resourcepack,
    ContentType.shader,
    ContentType.datapack,
    ContentType.plugin,
  },
  SourceKind.curseforge: {
    ContentType.mod,
    ContentType.modpack,
    ContentType.resourcepack,
    ContentType.shader,
    ContentType.datapack,
    ContentType.plugin,
  },
  SourceKind.hangar: {ContentType.plugin},
  SourceKind.spigot: {ContentType.plugin},
  SourceKind.github: {ContentType.repository},
  SourceKind.gitlab: {ContentType.repository},
  SourceKind.forgejo: {ContentType.repository},
};

class Searcher {
  final http.Client client;
  final Credentials credentials;
  final String curseforgeBaseUrl;
  Searcher(this.client, {this.credentials = const Credentials(), this.curseforgeBaseUrl = ''});

  Future<SearchOutcome> search(String query, {Set<SourceKind>? kinds, ContentType type = ContentType.any}) async {
    final q = query.trim();
    if (q.isEmpty) return const SearchOutcome([], {});
    final selected = (kinds ?? searchableKinds.keys.toSet()).where((k) {
      final types = searchableKinds[k];
      return types != null && (type == ContentType.any || types.contains(type));
    });
    final results = <SourceKind, List<SearchResult>>{};
    final errors = <SourceKind, String>{};
    await Future.wait(
      selected.map((k) async {
        try {
          results[k] = await _one(k, q, type).timeout(const Duration(seconds: 20));
        } catch (e) {
          errors[k] = redact('$e');
        }
      }),
    );
    // Interleave sources so one source does not push the others off screen.
    final merged = <SearchResult>[];
    final lists = results.values.toList();
    for (var i = 0; lists.any((l) => i < l.length); i++) {
      for (final l in lists) {
        if (i < l.length) merged.add(l[i]);
      }
    }
    return SearchOutcome(merged, errors);
  }

  Future<List<SearchResult>> _one(SourceKind k, String q, ContentType type) => switch (k) {
    SourceKind.modrinth => _modrinth(q, type),
    SourceKind.curseforge => _curseforge(q, type),
    SourceKind.hangar => _hangar(q),
    SourceKind.spigot => _spigot(q),
    SourceKind.github => _github(q),
    SourceKind.gitlab => _gitlab(q),
    SourceKind.forgejo => _codeberg(q),
    _ => Future.value(const []),
  };

  Future<List<SearchResult>> _modrinth(String q, ContentType type) async {
    final pt = switch (type) {
      ContentType.mod => 'mod',
      ContentType.modpack => 'modpack',
      ContentType.resourcepack => 'resourcepack',
      ContentType.shader => 'shader',
      ContentType.datapack => 'datapack',
      ContentType.plugin => 'plugin',
      _ => null,
    };
    final uri = Uri.https('api.modrinth.com', '/v2/search', {
      'query': q,
      'limit': '20',
      if (pt != null) 'facets': '[["project_type:$pt"]]',
    });
    final j = await getJson(client, uri) as Map;
    return [
      for (final h in ((j['hits'] as List?) ?? const []).cast<Map>())
        SearchResult(
          kind: SourceKind.modrinth,
          link: 'https://modrinth.com/${h['project_type'] ?? 'mod'}/${h['slug']}',
          title: '${h['title']}',
          description: h['description'] as String?,
          author: h['author'] as String?,
          iconUrl: h['icon_url'] as String?,
          downloads: h['downloads'] as int?,
          type: h['project_type'] as String?,
          updated: DateTime.tryParse('${h['date_modified'] ?? ''}'),
        ),
    ];
  }

  Future<List<SearchResult>> _curseforge(String q, ContentType type) async {
    final cf = CurseForgeSource(client, apiKey: credentials.curseforgeApiKey, baseUrl: curseforgeBaseUrl);
    final classId = switch (type) {
      ContentType.mod => '6',
      ContentType.modpack => '4471',
      ContentType.resourcepack => '12',
      ContentType.shader => '6552',
      ContentType.datapack => '6945',
      ContentType.plugin => '5',
      _ => null,
    };
    final j =
        await getJson(
              client,
              Uri.parse('${cf.baseUrl}/v1/mods/search').replace(
                queryParameters: {
                  'gameId': '${CurseForgeSource.minecraftGameId}',
                  'searchFilter': q,
                  'pageSize': '20',
                  'sortField': '2', // popularity
                  'sortOrder': 'desc',
                  'classId': ?classId,
                },
              ),
              headers: cf.headers,
            )
            as Map;
    return [
      for (final m in ((j['data'] as List?) ?? const []).cast<Map>())
        SearchResult(
          kind: SourceKind.curseforge,
          link: 'curseforge:${m['id']}',
          title: '${m['name']}',
          description: m['summary'] as String?,
          author: (((m['authors'] as List?) ?? const []).cast<Map>().firstOrNull)?['name'] as String?,
          iconUrl: (m['logo'] as Map?)?['thumbnailUrl'] as String?,
          downloads: (m['downloadCount'] as num?)?.toInt(),
          type: switch (m['classId']) {
            6 => 'mod',
            4471 => 'modpack',
            12 => 'resourcepack',
            6552 => 'shader',
            6945 => 'datapack',
            5 => 'plugin',
            _ => null,
          },
          updated: DateTime.tryParse('${m['dateModified'] ?? ''}'),
        ),
    ];
  }

  Future<List<SearchResult>> _hangar(String q) async {
    final j = await getJson(client, Uri.https('hangar.papermc.io', '/api/v1/projects', {'q': q, 'limit': '20'})) as Map;
    return [
      for (final p in ((j['result'] as List?) ?? const []).cast<Map>())
        SearchResult(
          kind: SourceKind.hangar,
          link: 'hangar:${(p['namespace'] as Map?)?['slug'] ?? p['name']}',
          title: '${p['name']}',
          description: p['description'] as String?,
          author: (p['namespace'] as Map?)?['owner'] as String?,
          iconUrl: p['avatarUrl'] as String?,
          downloads: ((p['stats'] as Map?)?['downloads'] as num?)?.toInt(),
          type: 'plugin',
        ),
    ];
  }

  Future<List<SearchResult>> _spigot(String q) async {
    final l =
        await getJson(
              client,
              Uri.parse('https://api.spiget.org/v2/search/resources/${Uri.encodeComponent(q)}?size=20&sort=-downloads'),
            )
            as List;
    return [
      for (final r in l.cast<Map>())
        if (r['premium'] != true)
          SearchResult(
            kind: SourceKind.spigot,
            link: 'spigot:${r['id']}',
            title: '${r['name']}',
            description: r['tag'] as String?,
            downloads: (r['downloads'] as num?)?.toInt(),
            type: 'plugin',
          ),
    ];
  }

  Future<List<SearchResult>> _github(String q) async {
    final token = credentials.githubToken;
    final uri = Uri.https('api.github.com', '/search/repositories', {'q': q, 'per_page': '20'});
    final j =
        await getJson(
              client,
              uri,
              headers: {
                'Accept': 'application/vnd.github+json',
                if (token.isNotEmpty && mayReceiveCredential('github', uri)) 'Authorization': 'Bearer $token',
              },
            )
            as Map;
    return [
      for (final r in ((j['items'] as List?) ?? const []).cast<Map>())
        SearchResult(
          kind: SourceKind.github,
          link: '${r['html_url']}',
          title: '${r['full_name']}',
          description: r['description'] as String?,
          author: (r['owner'] as Map?)?['login'] as String?,
          iconUrl: (r['owner'] as Map?)?['avatar_url'] as String?,
          downloads: (r['stargazers_count'] as num?)?.toInt(),
          type: 'repository',
          updated: DateTime.tryParse('${r['pushed_at'] ?? ''}'),
        ),
    ];
  }

  Future<List<SearchResult>> _gitlab(String q) async {
    final l =
        await getJson(
              client,
              Uri.https('gitlab.com', '/api/v4/projects', {'search': q, 'per_page': '20', 'order_by': 'star_count'}),
            )
            as List;
    return [
      for (final r in l.cast<Map>())
        SearchResult(
          kind: SourceKind.gitlab,
          link: '${r['web_url']}',
          title: '${r['path_with_namespace']}',
          description: r['description'] as String?,
          iconUrl: r['avatar_url'] as String?,
          downloads: (r['star_count'] as num?)?.toInt(),
          type: 'repository',
          updated: DateTime.tryParse('${r['last_activity_at'] ?? ''}'),
        ),
    ];
  }

  Future<List<SearchResult>> _codeberg(String q) async {
    final j = await getJson(client, Uri.https('codeberg.org', '/api/v1/repos/search', {'q': q, 'limit': '20'})) as Map;
    return [
      for (final r in ((j['data'] as List?) ?? const []).cast<Map>())
        SearchResult(
          kind: SourceKind.forgejo,
          link: '${r['html_url']}',
          title: '${r['full_name']}',
          description: r['description'] as String?,
          iconUrl: (r['owner'] as Map?)?['avatar_url'] as String?,
          downloads: (r['stars_count'] as num?)?.toInt(),
          type: 'repository',
        ),
    ];
  }
}
