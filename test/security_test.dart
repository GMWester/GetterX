import 'dart:convert';
import 'dart:io';

import 'package:getterx/core/credentials.dart';
import 'package:getterx/core/downloader.dart';
import 'package:getterx/core/models.dart';
import 'package:getterx/core/selector.dart';
import 'package:getterx/core/sources/curseforge.dart';
import 'package:getterx/core/sources/github.dart';
import 'package:getterx/core/sources/source.dart';
import 'package:getterx/core/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('credentials are only allowed to their own HTTPS host', () {
    expect(mayReceiveCredential('github', Uri.parse('https://api.github.com/x')), isTrue);
    expect(mayReceiveCredential('github', Uri.parse('http://api.github.com/x')), isFalse);
    expect(mayReceiveCredential('github', Uri.parse('https://api.github.com.evil.com/x')), isFalse);
    expect(mayReceiveCredential('github', Uri.parse('https://objects.githubusercontent.com/x')), isFalse);
    expect(mayReceiveCredential('curseforge', Uri.parse('https://api.curse.tools/v1/cf')), isFalse);
    expect(mayReceiveCredential('itchio', Uri.parse('https://evil.itch.io/x')), isFalse);
  });

  test('redaction removes tokens, keys and known secrets', () {
    redactionValues
      ..clear()
      ..add('supersecretvalue');
    final t = redact(
      'GET https://api.itch.io/x?api_key=abc123&page=2 Authorization: Bearer ghp_aaaaaaaaaaaaaaaaaaaaaaaaaa '
      'github_pat_11ABCDEFG0123456789_abcdefghij and supersecretvalue',
    );
    expect(t, isNot(contains('abc123')));
    expect(t, isNot(contains('ghp_')));
    expect(t, isNot(contains('github_pat_')));
    expect(t, isNot(contains('supersecretvalue')));
    expect(t, contains('page=2'));
    expect(SourceException('x?api_key=zzz').message, 'x?api_key=***');
    expect(LogEntry('error', 'token=abc').message, 'token=***');
    redactionValues.clear();
  });

  test('settings JSON never contains secrets', () {
    final j = jsonEncode(AppSettings().toJson());
    for (final k in Credentials.keys) {
      expect(j, isNot(contains(k)));
    }
  });

  test('download: auth header goes to origin only, dropped on cross-host redirect, no HTTPS downgrade', () async {
    final seen = <String, String?>{};
    final client = MockClient((req) async {
      seen[req.url.host] = req.headers['Authorization'];
      if (req.url.host == 'api.github.com') {
        return http.Response('', 302, headers: {'location': 'https://objects.githubusercontent.com/f?sig=1'});
      }
      if (req.url.host == 'down.grade') {
        return http.Response('', 302, headers: {'location': 'http://plain.example/f'});
      }
      return http.Response('data', 200);
    });
    final tmp = await Directory.systemTemp.createTemp('gxsec');
    await Downloader(client).download(
      const RemoteFile(
        name: 'a',
        urls: ['https://api.github.com/repos/o/r/releases/assets/1'],
        headers: {'Authorization': 'Bearer secret'},
      ),
      File(p.join(tmp.path, 'a')),
    );
    expect(seen['api.github.com'], 'Bearer secret');
    expect(seen['objects.githubusercontent.com'], isNull);
    await expectLater(
      Downloader(client)
          .download(const RemoteFile(name: 'b', urls: ['https://down.grade/x']), File(p.join(tmp.path, 'b'))),
      throwsA(isA<SourceException>()),
    );
    expect(seen.containsKey('plain.example'), isFalse);
    await expectLater(
      Downloader(client)
          .download(const RemoteFile(name: 'c', urls: ['http://plain.example/x']), File(p.join(tmp.path, 'c'))),
      throwsA(isA<SourceException>()),
    );
    await tmp.delete(recursive: true);
  });

  test('GitHub token is never attached to non-GitHub asset URLs', () async {
    final client = MockClient((req) async {
      expect(req.url.host, 'api.github.com');
      expect(req.headers['Authorization'], 'Bearer tok');
      return http.Response(
        jsonEncode([
          {
            'id': 1,
            'tag_name': 'v1',
            'name': 'v1',
            'draft': false,
            'prerelease': false,
            'published_at': '2026-01-01T00:00:00Z',
            'zipball_url': 'https://evil.example/zip',
            'assets': [
              {
                'name': 'a.apk',
                'url': 'https://api.github.com/repos/o/r/releases/assets/9',
                'browser_download_url': 'https://github.com/o/r/releases/download/v1/a.apk',
                'size': 1,
              },
              {
                'name': 'b.apk',
                'url': 'https://evil.example/asset',
                'browser_download_url': 'https://github.com/o/r/releases/download/v1/b.apk',
                'size': 1,
              },
            ],
          },
        ]),
        200,
      );
    });
    final rel = await GitHubSource(client, token: 'tok').fetchReleases(
      TrackedSource(id: 'x', kind: SourceKind.github, ref: 'o/r', name: 'r', includeSourceArchives: true),
    );
    final files = rel.single.files;
    expect(files[0].headers['Authorization'], 'Bearer tok');
    expect(files[1].headers, isEmpty);
    expect(files[1].urls, ['https://github.com/o/r/releases/download/v1/b.apk']);
    expect(files[2].headers, isEmpty);
  });

  test('CurseForge key is not sent to a custom/proxy base URL', () async {
    final client = MockClient((req) async {
      expect(req.headers.containsKey('x-api-key'), isFalse);
      return http.Response(
        jsonEncode({
          'data': [],
          'pagination': {'totalCount': 0},
        }),
        200,
      );
    });
    await CurseForgeSource(
      client,
      apiKey: 'k',
      baseUrl: 'https://api.curse.tools/v1/cf',
    ).fetchReleases(TrackedSource(id: 'x', kind: SourceKind.curseforge, ref: '1', name: 'm'));
  });

  test('remote file names cannot escape the download folder', () {
    for (final evil in ['../../etc/passwd', '..', r'..\..\win.ini', '/abs/path', 'C:\\x', 'CON', 'a\u0000b']) {
      final n = sanitizeName(evil);
      expect(n.contains('/') || n.contains('\\') || n == '..' || n == '.', isFalse, reason: evil);
      expect(p.isWithin('/root', p.join('/root', n)), isTrue, reason: evil);
    }
  });
}
