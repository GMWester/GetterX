/// HTTPS client that verifies certificates against the operating system's
/// trusted roots first and, if that fails, against Mozilla's root list that
/// ships with GetterX.
///
/// Why: on Windows, root certificates are often installed lazily (only when a
/// Microsoft program first needs them), so a perfectly valid site such as a CDN
/// can fail with CERTIFICATE_VERIFY_FAILED. Verification is never turned off: a
/// connection still fails unless the server's chain leads to a trusted root.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'mozilla_roots.dart';

http.Client createHttpClient() => FallbackTlsClient();

class FallbackTlsClient extends http.BaseClient {
  final http.Client _system = IOClient(HttpClient());
  http.Client? _bundled;

  /// Hosts whose certificates only verify with the bundled roots.
  final _bundledHosts = <String>{};

  http.Client get _bundledClient => _bundled ??= IOClient(HttpClient(context: mozillaContext()));

  static SecurityContext mozillaContext() =>
      SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(mozillaRootsPem));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    if (_bundledHosts.contains(host)) return _bundledClient.send(request);
    final retry = _copy(request);
    try {
      return await _system.send(request);
    } on HandshakeException {
      if (retry == null) rethrow;
      final res = await _bundledClient.send(retry);
      _bundledHosts.add(host);
      return res;
    } on http.ClientException catch (e) {
      // package:http may wrap the TLS error.
      if (retry == null || !e.message.contains('CERTIFICATE_VERIFY_FAILED')) rethrow;
      final res = await _bundledClient.send(retry);
      _bundledHosts.add(host);
      return res;
    }
  }

  static http.BaseRequest? _copy(http.BaseRequest r) {
    if (r is! http.Request) return null;
    return http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..bodyBytes = r.bodyBytes
      ..followRedirects = r.followRedirects
      ..maxRedirects = r.maxRedirects
      ..persistentConnection = r.persistentConnection;
  }

  @override
  void close() {
    _system.close();
    _bundled?.close();
  }
}
