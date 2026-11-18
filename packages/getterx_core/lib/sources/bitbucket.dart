import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';
import 'web.dart';

/// Bitbucket repository "Downloads". ref = "workspace/repo".
/// Files are grouped by the version number in their names.
class BitbucketSource implements ReleaseSource {
  final http.Client client;
  BitbucketSource(this.client);

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    final j = await getJson(client, Uri.parse('https://api.bitbucket.org/2.0/repositories/$ref')) as Map;
    return ProjectInfo(
      id: '${j['full_name'] ?? ref}',
      name: '${j['name'] ?? ref}',
      description: j['description'] as String?,
      pageUrl: 'https://bitbucket.org/$ref',
    );
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final files = <Map>[];
    String? next = 'https://api.bitbucket.org/2.0/repositories/${source.ref}/downloads?pagelen=100';
    while (next != null) {
      final j = await getJson(client, Uri.parse(next)) as Map;
      files.addAll(((j['values'] as List?) ?? const []).cast<Map>());
      next = full ? j['next'] as String? : null;
    }
    // Reuse the website grouping (version from the file name) via synthetic links.
    final html = files
        .map((f) => '<a href="${((f['links'] as Map?)?['self'] as Map?)?['href'] ?? ''}">${f['name']}</a>')
        .join('\n');
    return WebSource.parsePage(source, Uri.parse('https://bitbucket.org/${source.ref}/downloads/'), html);
  }
}
