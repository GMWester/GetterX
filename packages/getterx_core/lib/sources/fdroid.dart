import 'package:http/http.dart' as http;

import '../models.dart';
import 'source.dart';

/// F-Droid (f-droid.org) and F-Droid-style repos such as IzzyOnDroid.
/// ref = package name, e.g. org.fdroid.fdroid.
class FDroidSource implements ReleaseSource {
  final http.Client client;
  final String host;

  /// Path prefix of the repo on [host] ('' for f-droid.org, '/fdroid' for IzzyOnDroid).
  final String base;
  FDroidSource(this.client, {this.host = 'f-droid.org', this.base = ''});

  factory FDroidSource.izzy(http.Client client) => FDroidSource(client, host: 'apt.izzysoft.de', base: '/fdroid');

  String pageFor(String id) => base.isEmpty ? 'https://$host/packages/$id/' : 'https://$host$base/index/apk/$id';

  @override
  Future<ProjectInfo> fetchProject(String ref) async {
    await getJson(client, Uri.https(host, '$base/api/v1/packages/$ref')); // validates the id
    return ProjectInfo(id: ref, name: ref, pageUrl: pageFor(ref));
  }

  @override
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source, {bool full = true}) async {
    final j = await getJson(client, Uri.https(host, '$base/api/v1/packages/${source.ref}')) as Map<String, dynamic>;
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
            RemoteFile(name: '${source.ref}_$code.apk', urls: ['https://$host$base/repo/${source.ref}_$code.apk']),
          ],
          pageUrl: pageFor(source.ref),
          order: out.length,
        ),
      );
    }
    return out;
  }
}
