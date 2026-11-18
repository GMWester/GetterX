import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// SpigotMC resources via the SpiGet API. ref = numeric resource id.
/// SpiGet can only serve the newest file of free resources hosted on SpigotMC,
/// so this source always provides the latest version.
class SpigotSource implements ReleaseSource {
  final http.Client client;
  final String api;
  SpigotSource(this.client, {this.api = 'https://api.spiget.org/v2'});

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(client, Uri.parse('$api/resources/$ref')) as Map;
    final icon = (j['icon'] as Map?)?['url'] as String?;
    return ProjectInfo(
      id: '${j['id'] ?? ref}',
      name: (j['name'] ?? ref) as String,
      description: j['tag'] as String?,
      iconUrl: icon != null && icon.isNotEmpty ? 'https://www.spigotmc.org/$icon' : null,
      pageUrl: 'https://www.spigotmc.org/resources/$ref/',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final r = await getJson(client, Uri.parse('$api/resources/${source.ref}')) as Map;
    final versions =
        await getJson(client, Uri.parse('$api/resources/${source.ref}/versions?size=1&sort=-releaseDate')) as List;
    return [?buildLatest(r.cast(), versions.cast<Map>(), source.ref)];
  }

  static RemoteRelease? buildLatest(Map<String, dynamic> r, List<Map> versions, String ref) {
    if (r['premium'] == true) {
      throw SourceException('This SpigotMC resource is premium; it cannot be downloaded automatically.');
    }
    final file = (r['file'] as Map?) ?? const {};
    if (r['external'] == true || file['type'] == 'external') {
      throw SourceException(
        'This SpigotMC resource is hosted elsewhere (${file['externalUrl'] ?? 'external link'}); '
        'track that site instead.',
      );
    }
    if (versions.isEmpty) return null;
    final v = versions.first;
    final name = '${v['name'] ?? 'latest'}';
    final ext = '${file['type'] ?? '.jar'}'.startsWith('.') ? '${file['type'] ?? '.jar'}' : '.jar';
    final safe = '${r['name'] ?? ref}'.replaceAll(RegExp(r'[^\w.-]+'), '_');
    return RemoteRelease(
      id: 'v${v['id']}',
      version: name,
      title: name,
      publishedAt: v['releaseDate'] is int
          ? DateTime.fromMillisecondsSinceEpoch((v['releaseDate'] as int) * 1000, isUtc: true)
          : null,
      channel: ReleaseChannel.release,
      gameVersions: ((r['testedVersions'] as List?) ?? const []).map((e) => '$e').toList(),
      files: [
        RemoteFile(name: '$safe-$name$ext', urls: ['https://api.spiget.org/v2/resources/$ref/download'], primary: true),
      ],
      pageUrl: 'https://www.spigotmc.org/resources/$ref/updates',
    );
  }
}
