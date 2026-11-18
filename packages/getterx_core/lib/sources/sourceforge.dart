import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../version_utils.dart';
import 'source.dart';
import 'web.dart' show HttpDateParser;

/// SourceForge projects. ref = project name (e.g. "keepass"), optionally
/// followed by a folder: "project/path/to/folder".
///
/// Uses the project's file RSS feed. Files in the same folder form one
/// release; files in the project root are grouped by the version number in
/// their name.
class SourceForgeSource implements ReleaseSource {
  final http.Client client;
  SourceForgeSource(this.client);

  (String project, String path) _split(String ref) {
    final i = ref.indexOf('/');
    return i < 0 ? (ref, '/') : (ref.substring(0, i), '/${ref.substring(i + 1)}');
  }

  Future<String> _feed(String ref) async {
    final (project, path) = _split(ref);
    final uri = Uri.https('sourceforge.net', '/projects/$project/rss', {'path': path, 'limit': '500'});
    final res = await client.get(uri, headers: {'User-Agent': userAgent});
    if (res.statusCode == 404) throw SourceException('SourceForge project "$project" not found');
    if (res.statusCode >= 400) throw SourceException('HTTP ${res.statusCode} from sourceforge.net');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final xml = await _feed(ref);
    final (project, _) = _split(ref);
    final title = RegExp(
      r'<channel>\s*<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>',
      dotAll: true,
    ).firstMatch(xml)?[1];
    var name = (title ?? project).trim();
    // Feed titles look like "Project Name from SourceForge.net".
    name = name.replaceFirst(RegExp(r'\s+from SourceForge\.net$'), '');
    return ProjectInfo(
      id: ref,
      name: name.isEmpty ? project : name,
      pageUrl: 'https://sourceforge.net/projects/$project/',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async =>
      parseFeed(await _feed(source.ref), source.ref);

  static List<RemoteRelease> parseFeed(String xml, String ref) {
    final project = ref.split('/').first;
    final items = RegExp(r'<item>(.*?)</item>', dotAll: true).allMatches(xml);
    final groups = <String, List<(RemoteFile, DateTime?)>>{};
    for (final m in items) {
      final it = m[1]!;
      String? tag(String name) =>
          RegExp('<$name[^>]*>(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?</$name>', dotAll: true).firstMatch(it)?[1]?.trim();
      final title = tag('title');
      final link = tag('link');
      if (title == null || link == null || !link.startsWith('https://')) continue;
      final parts = title.split('/').where((e) => e.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      final fileName = parts.last;
      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      DateTime? date;
      try {
        final d = tag('pubDate');
        if (d != null) date = HttpDateParser.parse(d);
      } catch (_) {}
      final size = int.tryParse(RegExp(r'filesize="(\d+)"').firstMatch(it)?[1] ?? '');
      final md5 = RegExp(r'<media:hash algo="md5">([0-9a-fA-F]{32})</media:hash>').firstMatch(it)?[1];
      final key = folder.isNotEmpty ? folder : (RegExp(r'\d+(?:\.\d+)+').firstMatch(fileName)?[0] ?? fileName);
      (groups[key] ??= []).add((
        RemoteFile(name: fileName, urls: [link], size: size, hashes: {if (md5 != null) 'md5': md5.toLowerCase()}),
        date,
      ));
    }
    final out = <RemoteRelease>[];
    for (final e in groups.entries) {
      final newest = e.value
          .map((x) => x.$2)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
      final version = e.key.split('/').last;
      out.add(
        RemoteRelease(
          id: 'sf:${e.key}',
          version: version,
          title: e.key,
          publishedAt: newest,
          channel: RegExp(r'(alpha|beta|rc|pre|nightly|snapshot)', caseSensitive: false).hasMatch(e.key)
              ? ReleaseChannel.beta
              : ReleaseChannel.release,
          files: e.value.map((x) => x.$1).toList(),
          pageUrl: 'https://sourceforge.net/projects/$project/files/${e.key}/',
        ),
      );
    }
    out.sort((a, b) {
      final da = a.publishedAt, db = b.publishedAt;
      if (da != null && db != null && da != db) return db.compareTo(da);
      return compareVersions(b.version, a.version);
    });
    return [for (var i = 0; i < out.length; i++) _withOrder(out[i], i)];
  }

  static RemoteRelease _withOrder(RemoteRelease r, int i) => RemoteRelease(
    id: r.id,
    version: r.version,
    title: r.title,
    publishedAt: r.publishedAt,
    channel: r.channel,
    files: r.files,
    pageUrl: r.pageUrl,
    order: i,
  );
}
