import 'dart:convert';
import 'dart:io';

import 'package:getterx_core/engine.dart';
import 'package:getterx_core/platform_match.dart';
import 'package:getterx_core/store.dart';
import 'package:getterx_core/web_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('Lite web UI: token, host check, add/edit/remove', () async {
    final tmp = await Directory.systemTemp.createTemp('gxweb');
    final store = ConfigStore(Directory(p.join(tmp.path, 'data')));
    await store.load();
    final mock = MockClient((req) async {
      if (req.url.path.endsWith('/version')) return http.Response('[]', 200);
      return http.Response(jsonEncode({'slug': 'sodium', 'title': 'Sodium', 'project_type': 'mod'}), 200);
    });
    final engine = Engine(
      store,
      client: mock,
      platform: const PlatformInfo('linux', 'x64'),
      defaultDownloadRoot: tmp.path,
    );
    final ui = WebUi(engine, store);
    final url = await ui.start(port: 0);
    final base = 'http://127.0.0.1:${url.port}';
    final c = http.Client();
    Future<http.Response> post(String path, Object body, {String? token, Map<String, String>? extra}) => c.post(
      Uri.parse('$base$path'),
      headers: {'X-GetterX-Token': token ?? ui.token, 'Content-Type': 'application/json', ...?extra},
      body: jsonEncode(body),
    );

    expect((await c.get(Uri.parse('$base/'))).body, contains('GetterX'));
    expect((await c.get(Uri.parse('$base/api/state'))).statusCode, 401); // no token
    expect((await post('/api/state', {}, token: 'wrong')).statusCode, 401);
    // DNS rebinding: foreign Host header is refused even with the token.
    final rq = await HttpClient().getUrl(Uri.parse('$base/api/state'));
    rq.headers
      ..set('Host', 'evil.example')
      ..set('X-GetterX-Token', ui.token);
    expect((await rq.close()).statusCode, 403);

    final add = await post('/api/add', {'link': 'https://modrinth.com/mod/sodium'});
    expect(add.statusCode, 200, reason: add.body);
    final id = jsonDecode(add.body)['id'] as String;
    final upd = await post('/api/source', {
      'id': id,
      'loaders': ['fabric'],
      'downloadDir': '/x/y',
    });
    expect(upd.statusCode, 200, reason: upd.body);
    expect((await post('/api/source', {'id': id, 'includeFilesRegex': '('})).statusCode, 400);
    final state = jsonDecode((await c.get(Uri.parse('$base/api/state'), headers: {'X-GetterX-Token': ui.token})).body);
    expect(state['sources'][0]['loaders'], ['fabric']);
    expect(state['sources'][0]['folder'], '/x/y');
    expect((await post('/api/remove', {'id': id})).statusCode, 200);
    await ui.close();
    c.close();
    await tmp.delete(recursive: true);
  });
}
