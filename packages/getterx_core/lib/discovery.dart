/// "Also available on": finds the same project on other sources.
///
/// * CurseForge → Modrinth: exact match by the file's SHA-1 (Modrinth can look
///   a file up by hash), then by slug / name.
/// * Modrinth → CurseForge: by slug and name (CurseForge cannot be searched by
///   SHA-1), confirmed by matching author when possible.
/// * Mods → GitHub / GitLab / Codeberg: the "source code" link of the project.
/// * Android apps → F-Droid / IzzyOnDroid: by package id.
library;

import 'package:http/http.dart' as http;

import 'credentials.dart';
import 'link_parser.dart';
import 'models.dart';
import 'sources/curseforge.dart';
import 'sources/source.dart';

class Alternative {
  final SourceKind kind;
  final String link;
  final String title;

  /// Why we think it is the same project (shown to the user).
  final String reason;

  /// 3 = exact (same file hash / package id), 2 = strong (slug + name), 1 = likely (name / link).
  final int confidence;
  const Alternative(this.kind, this.link, this.title, this.reason, this.confidence);
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

class Discovery {
  final http.Client client;
  final Credentials credentials;
  final String curseforgeBaseUrl;
  Discovery(this.client, {this.credentials = const Credentials(), this.curseforgeBaseUrl = ''});

  CurseForgeSource get _cf =>
      CurseForgeSource(client, apiKey: credentials.curseforgeApiKey, baseUrl: curseforgeBaseUrl);

  Future<List<Alternative>> find(TrackedSource s, {List<RemoteRelease> releases = const []}) async {
    final out = <Alternative>[];
    Future<void> attempt(Future<void> Function() f) async {
      try {
        await f().timeout(const Duration(seconds: 20));
      } catch (_) {
        // Discovery is best-effort: a failing source just shows nothing.
      }
    }

    switch (s.kind) {
      case SourceKind.modrinth:
        Map? project;
        await attempt(() async {
          project =
              await getJson(client, Uri.parse('https://api.modrinth.com/v2/project/${Uri.encodeComponent(s.ref)}'))
                  as Map;
        });
        final p = project;
        if (p != null) {
          _codeLink(p['source_url'] as String?, out);
          await attempt(
            () async => out.addAll(await _curseforgeFor('${p['slug'] ?? s.ref}', '${p['title'] ?? s.name}')),
          );
        }
      case SourceKind.curseforge:
        Map? mod;
        await attempt(() async {
          final j = await getJson(client, Uri.parse('${_cf.baseUrl}/v1/mods/${s.ref}'), headers: _cf.headers) as Map;
          mod = j['data'] as Map?;
        });
        final m = mod;
        _codeLink(((m?['links'] as Map?)?['sourceUrl']) as String?, out);
        await attempt(() async => out.addAll(await _modrinthFor(s, releases, m)));
      case SourceKind.fdroid:
      case SourceKind.izzyondroid:
      case SourceKind.github:
      case SourceKind.gitlab:
      case SourceKind.forgejo:
      case SourceKind.web:
        break;
      default:
        break;
    }
    final pkg = s.packageId;
    if (pkg != null && pkg.isNotEmpty) {
      if (s.kind != SourceKind.fdroid) {
        await attempt(() async {
          await getJson(client, Uri.https('f-droid.org', '/api/v1/packages/$pkg'));
          out.add(Alternative(SourceKind.fdroid, 'fdroid:$pkg', pkg, 'Same package id', 3));
        });
      }
      if (s.kind != SourceKind.izzyondroid) {
        await attempt(() async {
          await getJson(client, Uri.https('apt.izzysoft.de', '/fdroid/api/v1/packages/$pkg'));
          out.add(Alternative(SourceKind.izzyondroid, 'izzy:$pkg', pkg, 'Same package id', 3));
        });
      }
    }
    // Drop duplicates and the source itself; best match first.
    final seen = <String>{'${s.kind.name}:${s.ref.toLowerCase()}'};
    final unique = <Alternative>[];
    for (final a in out..sort((x, y) => y.confidence.compareTo(x.confidence))) {
      final p = parseSourceLink(a.link);
      final key = p == null ? a.link : '${p.kind.name}:${p.ref.toLowerCase()}';
      if (seen.add(key)) unique.add(a);
    }
    return unique;
  }

  void _codeLink(String? url, List<Alternative> out) {
    if (url == null || url.isEmpty) return;
    final p = parseSourceLink(url);
    if (p == null || p.kind == SourceKind.web) return;
    out.add(Alternative(p.kind, url, p.ref, 'Listed as the source code', 2));
  }

  Future<List<Alternative>> _curseforgeFor(String slug, String title) async {
    final res = <Alternative>[];
    Future<List<Map>> search(Map<String, String> q) async {
      final j =
          await getJson(
                client,
                Uri.parse(
                  '${_cf.baseUrl}/v1/mods/search',
                ).replace(queryParameters: {'gameId': '${CurseForgeSource.minecraftGameId}', 'pageSize': '10', ...q}),
                headers: _cf.headers,
              )
              as Map;
      return ((j['data'] as List?) ?? const []).cast<Map>();
    }

    for (final m in [
      ...await search({'slug': slug}),
      ...await search({'searchFilter': title}),
    ]) {
      final sameSlug = m['slug'] == slug;
      final sameName = _norm('${m['name']}') == _norm(title);
      if (!sameSlug && !sameName) continue;
      res.add(
        Alternative(
          SourceKind.curseforge,
          'curseforge:${m['id']}',
          '${m['name']}',
          sameSlug && sameName ? 'Same name and slug' : (sameSlug ? 'Same slug' : 'Same name'),
          sameSlug && sameName ? 2 : 1,
        ),
      );
    }
    return res;
  }

  Future<List<Alternative>> _modrinthFor(TrackedSource s, List<RemoteRelease> releases, Map? cfMod) async {
    final res = <Alternative>[];
    // 1) Exact: Modrinth knows the file by its SHA-1.
    for (final r in releases.take(5)) {
      for (final f in r.files) {
        final sha1 = f.hashes['sha1'];
        if (sha1 == null) continue;
        try {
          final v =
              await getJson(client, Uri.parse('https://api.modrinth.com/v2/version_file/$sha1?algorithm=sha1')) as Map;
          final p = await getJson(client, Uri.parse('https://api.modrinth.com/v2/project/${v['project_id']}')) as Map;
          res.add(
            Alternative(
              SourceKind.modrinth,
              'https://modrinth.com/${p['project_type'] ?? 'mod'}/${p['slug']}',
              '${p['title']}',
              'Same file (SHA-1 match)',
              3,
            ),
          );
          return res;
        } catch (_) {
          // Not on Modrinth under this hash; try the next file.
        }
      }
    }
    // 2) Slug / name.
    final slug = cfMod?['slug'] as String?;
    final name = '${cfMod?['name'] ?? s.name}';
    if (slug != null) {
      try {
        final p =
            await getJson(client, Uri.parse('https://api.modrinth.com/v2/project/${Uri.encodeComponent(slug)}')) as Map;
        final sameName = _norm('${p['title']}') == _norm(name);
        res.add(
          Alternative(
            SourceKind.modrinth,
            'https://modrinth.com/${p['project_type'] ?? 'mod'}/${p['slug']}',
            '${p['title']}',
            sameName ? 'Same name and slug' : 'Same slug',
            sameName ? 2 : 1,
          ),
        );
      } catch (_) {}
    }
    final j = await getJson(client, Uri.https('api.modrinth.com', '/v2/search', {'query': name, 'limit': '5'})) as Map;
    for (final h in ((j['hits'] as List?) ?? const []).cast<Map>()) {
      if (_norm('${h['title']}') != _norm(name)) continue;
      res.add(
        Alternative(
          SourceKind.modrinth,
          'https://modrinth.com/${h['project_type'] ?? 'mod'}/${h['slug']}',
          '${h['title']}',
          'Same name',
          1,
        ),
      );
    }
    return res;
  }
}
