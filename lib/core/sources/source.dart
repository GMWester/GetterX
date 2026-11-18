import 'dart:convert';

import 'package:http/http.dart' as http;

import '../credentials.dart';
import '../models.dart';

const userAgent = 'GetterX/1.0 (+https://github.com/gmwester/GetterX)';

class SourceException implements Exception {
  final String message;
  SourceException(String message) : message = redact(message);
  @override
  String toString() => message;
}

abstract class ReleaseSource {
  /// Resolves basic project info (name, canonical id).
  Future<ProjectInfo> fetchProject(String ref);

  /// Returns releases, newest first. [full] = false allows sources to stop
  /// after the first page when only the newest releases are needed.
  Future<List<RemoteRelease>> fetchReleases(TrackedSource source,
      {bool full = true});
}

Future<dynamic> getJson(http.Client client, Uri uri,
    {Map<String, String> headers = const {}}) async {
  if (uri.scheme != 'https') throw SourceException('Refusing non-HTTPS request to ${uri.host}');
  final res = await client.get(uri, headers: {
    'User-Agent': userAgent,
    'Accept': 'application/json',
    ...headers,
  });
  if (res.statusCode == 404) {
    throw SourceException('Not found: $uri');
  }
  if (res.statusCode == 403 || res.statusCode == 429) {
    final reset = res.headers['x-ratelimit-reset'];
    var hint = '';
    if (reset != null) {
      final t = DateTime.fromMillisecondsSinceEpoch(int.parse(reset) * 1000);
      hint = ' (rate limit resets at ${t.toLocal()})';
    }
    throw SourceException(
        'HTTP ${res.statusCode} from ${uri.host}$hint. Add an API token in Settings if this repeats.');
  }
  if (res.statusCode >= 400) {
    throw SourceException('HTTP ${res.statusCode} from $uri: ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
  }
  return jsonDecode(utf8.decode(res.bodyBytes));
}
