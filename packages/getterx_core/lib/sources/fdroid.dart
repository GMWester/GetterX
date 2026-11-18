import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// F-Droid (f-droid.org) apps. ref = package name, e.g. org.fdroid.fdroid.
class FDroidSource implements ReleaseSource {
  final http.Client client;
  final String host;
  FDroidSource(this.client, {this.host = 'f-droid.org'});

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    await getJson(client, Uri.https(host, '/api/v1/packages/$ref')); // validates the id
    return ProjectInfo(id: ref, name: ref, pageUrl: 'https://$host/packages/$ref/');
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final j = await getJson(client, Uri.https(host, '/api/v1/packages/${source.ref}')) as Map<String, dynamic>;
    final suggested = j['suggestedVersionCode'];
    final pkgs = (j['packages'] as List? ?? const []).cast<Map<String, dynamic>>().toList()
      ..sort((a, b) => (b['versionCode'] as int).compareTo(a['versionCode'] as int));
    final out = <RemoteRelease>[];
    for (final p in pkgs) {
      final code = p['versionCode'] as int;
      out.add(
        RemoteRelease(
          id: '$code',
          version: '${p['versionName']}',
          title: '${p['versionName']} ($code)',
          publishedAt: null,
          // Builds newer than the suggested one are not yet recommended by F-Droid.
          channel: suggested is int && code > suggested ? ReleaseChannel.beta : ReleaseChannel.release,
          files: [
            RemoteFile(name: '${source.ref}_$code.apk', urls: ['https://$host/repo/${source.ref}_$code.apk']),
          ],
          pageUrl: 'https://$host/packages/${source.ref}/',
          order: out.length,
        ),
      );
    }
    return out;
  }
}
