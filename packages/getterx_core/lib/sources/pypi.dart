import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// Python packages from PyPI. ref = package name.
class PyPiSource implements ReleaseSource {
  final http.Client client;
  PyPiSource(this.client);

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(client, Uri.parse('https://pypi.org/pypi/$ref/json')) as Map;
    final info = (j['info'] as Map?) ?? const {};
    return ProjectInfo(
      id: '${info['name'] ?? ref}',
      name: '${info['name'] ?? ref}',
      description: info['summary'] as String?,
      pageUrl: 'https://pypi.org/project/$ref/',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final j = await getJson(client, Uri.parse('https://pypi.org/pypi/${source.ref}/json')) as Map;
    return parse((j['releases'] as Map?) ?? const {}, source.ref);
  }

  static List<RemoteRelease> parse(Map releases, String ref) {
    final out = <RemoteRelease>[];
    for (final e in releases.entries) {
      final files = ((e.value as List?) ?? const []).cast<Map>().where((f) => f['yanked'] != true).toList();
      if (files.isEmpty) continue;
      DateTime? date;
      for (final f in files) {
        final d = DateTime.tryParse('${f['upload_time_iso_8601'] ?? ''}');
        if (d != null && (date == null || d.isAfter(date))) date = d;
      }
      final v = '${e.key}';
      out.add(
        RemoteRelease(
          id: v,
          version: v,
          title: v,
          publishedAt: date,
          channel: RegExp(r'(a|b|rc|dev)\d*$').hasMatch(v) ? ReleaseChannel.beta : ReleaseChannel.release,
          files: [
            for (final f in files)
              RemoteFile(
                name: '${f['filename']}',
                urls: ['${f['url']}'],
                size: f['size'] as int?,
                hashes: {
                  if ((f['digests'] as Map?)?['sha256'] is String) 'sha256': '${(f['digests'] as Map)['sha256']}',
                },
              ),
          ],
          pageUrl: 'https://pypi.org/project/$ref/$v/',
        ),
      );
    }
    out.sort((a, b) => (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0)));
    return out;
  }
}
