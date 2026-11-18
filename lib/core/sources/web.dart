import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import '../version_utils.dart';
import 'source.dart';

/// Any website that is not a built-in source.
///
/// * Download page: every link on the page that looks like a file (or
///   matches [TrackedSource.linkRegex]) is collected, the version is read from
///   each link, and links are grouped into one "release" per version.
/// * Direct file URL: the file itself is tracked; a change of ETag,
///   Last-Modified or size counts as a new release.
class WebSource implements ReleaseSource {
  final http.Client client;
  WebSource(this.client);

  static const fileExtensions = [
    'apk',
    'aab',
    'xapk',
    'apks',
    'exe',
    'msi',
    'msix',
    'msixbundle',
    'appx',
    'zip',
    '7z',
    'rar',
    'dmg',
    'pkg',
    'appimage',
    'deb',
    'rpm',
    'flatpak',
    'snap',
    'jar',
    'mrpack',
    'ipa',
    'iso',
    'img',
    'bin',
    'tar.gz',
    'tgz',
    'tar.xz',
    'txz',
    'tar.bz2',
    'tar.zst',
    'gz',
    'xz',
    'pdf',
  ];

  static bool looksLikeFile(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return fileExtensions.any((e) => path.endsWith('.$e'));
  }

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final uri = Uri.parse(ref);
    if (uri.scheme != 'https') throw SourceException('Only https:// links are supported');
    if (looksLikeFile(ref)) {
      return ProjectInfo(id: ref, name: Uri.decodeComponent(uri.pathSegments.last), pageUrl: ref);
    }
    final res = await client.get(uri, headers: {'User-Agent': userAgent});
    if (res.statusCode >= 400) throw SourceException('HTTP ${res.statusCode} from ${uri.host}');
    final title = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(utf8.decode(res.bodyBytes, allowMalformed: true))?[1]?.trim();
    return ProjectInfo(id: ref, name: _unescape(title ?? uri.host), pageUrl: ref);
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final uri = Uri.parse(source.ref);
    if (uri.scheme != 'https') throw SourceException('Only https:// links are supported');
    if (looksLikeFile(source.ref) && source.linkRegex.isEmpty) return [await _directFile(uri)];
    final res = await client.get(uri, headers: {'User-Agent': userAgent, 'Accept': 'text/html,*/*'});
    if (res.statusCode >= 400) throw SourceException('HTTP ${res.statusCode} from ${uri.host}');
    return parsePage(source, uri, utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  Future<RemoteRelease> _directFile(Uri uri) async {
    final res = await client.head(uri, headers: {'User-Agent': userAgent});
    if (res.statusCode >= 400) throw SourceException('HTTP ${res.statusCode} from ${uri.host}');
    final etag = res.headers['etag'] ?? '';
    final modified = res.headers['last-modified'] ?? '';
    final length = res.headers['content-length'] ?? '';
    if (etag.isEmpty && modified.isEmpty && length.isEmpty) {
      throw SourceException('${uri.host} gives no ETag / Last-Modified / size; updates cannot be detected');
    }
    final date = _httpDate(modified);
    final id = sha1.convert(utf8.encode('$etag|$modified|$length')).toString().substring(0, 16);
    final name = Uri.decodeComponent(uri.pathSegments.last);
    return RemoteRelease(
      id: id,
      version: date != null ? '${date.toIso8601String().substring(0, 10)}_$id'.substring(0, 19) : id,
      title: name,
      publishedAt: date,
      channel: ReleaseChannel.release,
      files: [
        RemoteFile(name: name, urls: [uri.toString()], size: int.tryParse(length)),
      ],
      pageUrl: uri.toString(),
    );
  }

  static List<RemoteRelease> parsePage(TrackedSource s, Uri page, String html) {
    final linkRe = s.linkRegex.trim().isEmpty ? null : RegExp(s.linkRegex, caseSensitive: false);
    final verRe = s.versionExtractRegex.trim().isEmpty ? null : RegExp(s.versionExtractRegex, caseSensitive: false);
    final anchors = RegExp(
      r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>''',
      caseSensitive: false,
      dotAll: true,
    );
    final seen = <String>{};
    final byVersion = <String, List<RemoteFile>>{};
    final firstSeen = <String, int>{};
    var index = 0;
    for (final m in anchors.allMatches(html)) {
      final raw = _unescape((m[1] ?? m[2] ?? m[3] ?? '').trim());
      if (raw.isEmpty || raw.startsWith('#') || raw.startsWith('javascript:') || raw.startsWith('mailto:')) continue;
      Uri url;
      try {
        url = page.resolve(raw);
      } catch (_) {
        continue;
      }
      if (url.scheme != 'https') continue;
      final full = url.toString();
      if (linkRe != null ? !linkRe.hasMatch(full) : !looksLikeFile(full)) continue;
      if (!seen.add(full)) continue;
      final text = _unescape(m[4]!.replaceAll(RegExp(r'<[^>]+>'), ' ')).trim();
      final segs = url.pathSegments.where((e) => e.isNotEmpty).toList();
      final name = segs.isEmpty ? url.host : Uri.decodeComponent(segs.last);
      String? version;
      if (verRe != null) {
        final vm = verRe.firstMatch(full) ?? verRe.firstMatch(text);
        version = vm == null ? null : (vm.groupCount >= 1 ? vm[1] : vm[0]);
      } else {
        version = RegExp(r'\d+(?:\.\d+)+').firstMatch(name)?[0] ?? RegExp(r'\d+(?:\.\d+)+').firstMatch(text)?[0];
      }
      final key = version ?? '';
      firstSeen.putIfAbsent(key, () => index++);
      (byVersion[key] ??= []).add(RemoteFile(name: name, urls: [full]));
    }
    final versions = byVersion.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty || b.isEmpty) return a.isEmpty ? 1 : -1;
        final c = compareVersions(b, a);
        return c != 0 ? c : firstSeen[a]!.compareTo(firstSeen[b]!);
      });
    final out = <RemoteRelease>[];
    for (final v in versions) {
      final files = byVersion[v]!;
      final id = v.isNotEmpty
          ? 'v:$v'
          : 'u:${sha1.convert(utf8.encode(files.map((f) => f.urls.first).join('|'))).toString().substring(0, 16)}';
      out.add(
        RemoteRelease(
          id: id,
          version: v.isEmpty ? 'unversioned' : v,
          title: v.isEmpty ? 'Files without a version' : v,
          publishedAt: null,
          channel: ReleaseChannel.release,
          files: files,
          pageUrl: page.toString(),
          order: out.length,
        ),
      );
    }
    return out;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x2F;', '/')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static DateTime? _httpDate(String v) {
    if (v.isEmpty) return null;
    try {
      return HttpDateParser.parse(v);
    } catch (_) {
      return null;
    }
  }
}

/// Minimal RFC 7231 date parser ("Tue, 15 Nov 1994 08:12:31 GMT").
class HttpDateParser {
  static const _m = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  static DateTime parse(String v) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(v)!;
    return DateTime.utc(
      int.parse(m[3]!),
      _m[m[2]!.toLowerCase()]!,
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
