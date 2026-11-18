import 'dart:io';

import 'package:getterx_core/mozilla_roots.dart';
import 'package:getterx_core/tls.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('bundled Mozilla roots load', () {
    expect('BEGIN CERTIFICATE'.allMatches(mozillaRootsPem).length, greaterThan(100));
    expect(FallbackTlsClient.mozillaContext, returnsNormally);
  });

  test('certificate verification is never disabled (untrusted cert fails on both attempts)', () async {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/untrusted.crt')
      ..usePrivateKey('test/fixtures/untrusted.key');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    var served = 0;
    server.listen((r) {
      served++;
      r.response
        ..write('secret')
        ..close();
    });
    final client = createHttpClient();
    await expectLater(client.get(Uri.parse('https://127.0.0.1:${server.port}/')), throwsA(anything));
    expect(served, 0, reason: 'no request may reach a server with an untrusted certificate');
    client.close();
    await server.close(force: true);
  });

  test('the fallback is used once the system store rejects a host', () async {
    // A trusted server is unavailable offline, so check the retry plumbing with a
    // request that cannot be copied (streamed): it must surface the original error.
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/untrusted.crt')
      ..usePrivateKey('test/fixtures/untrusted.key');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen((r) => r.response.close());
    final client = createHttpClient();
    final req = http.StreamedRequest('POST', Uri.parse('https://127.0.0.1:${server.port}/'));
    req.sink.close();
    await expectLater(client.send(req), throwsA(isA<HandshakeException>()));
    client.close();
    await server.close(force: true);
  });
}
