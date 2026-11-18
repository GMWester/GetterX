import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// Thunderstore game mods. ref = "Namespace/Name". Provides the latest version.
class ThunderstoreSource implements ReleaseSource {
  final http.Client client;
  ThunderstoreSource(this.client);

  Future<Map> _pkg(String ref) =>
      getJson(client, Uri.parse('https://thunderstore.io/api/experimental/package/$ref/')).then((v) => v as Map);

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await _pkg(ref);
    final latest = (j['latest'] as Map?) ?? const {};
    return ProjectInfo(
      id: '${j['namespace']}/${j['name']}',
      name: '${j['name'] ?? ref}'.replaceAll('_', ' '),
      description: latest['description'] as String?,
      iconUrl: latest['icon'] as String?,
      pageUrl: j['package_url'] as String?,
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final j = await _pkg(source.ref);
    final l = (j['latest'] as Map?) ?? const {};
    final url = l['download_url'] as String?;
    if (url == null) return [];
    return [
      RemoteRelease(
        id: '${l['full_name'] ?? l['version_number']}',
        version: '${l['version_number']}',
        title: '${l['version_number']}',
        publishedAt: DateTime.tryParse('${l['date_created'] ?? ''}'),
        channel: ReleaseChannel.release,
        files: [
          RemoteFile(name: '${l['full_name'] ?? source.ref.replaceAll('/', '-')}.zip', urls: [url], primary: true),
        ],
        pageUrl: j['package_url'] as String?,
      ),
    ];
  }
}
