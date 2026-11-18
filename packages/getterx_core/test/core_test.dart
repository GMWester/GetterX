import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:getterx_core/engine.dart';
import 'package:getterx_core/link_parser.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/platform_match.dart';
import 'package:getterx_core/selector.dart';
import 'package:getterx_core/sources/curseforge.dart';
import 'package:getterx_core/sources/itchio.dart';
import 'package:getterx_core/sources/modrinth.dart';
import 'package:getterx_core/sources/web.dart';
import 'package:getterx_core/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const linux = PlatformInfo('linux', 'x64');

Map<String, dynamic> mrVersion(
  String id,
  String loader,
  List<String> games,
  String version,
  DateTime date, {
  String type = 'release',
}) => {
  'id': id,
  'name': '$loader-$version',
  'version_number': version,
  'version_type': type,
  'loaders': [loader],
  'game_versions': games,
  'date_published': date.toIso8601String(),
  'files': [
    {
      'filename': '${loader}_$version.jar',
      'url': 'https://cdn.modrinth.com/data/x/versions/$id/${loader}_$version.jar',
      'primary': true,
      'size': 10,
      'hashes': {'sha1': sha1.convert(utf8.encode('jar:$id')).toString()},
    },
    {
      'filename': '${loader}_$version-sources.jar',
      'url': 'https://cdn.modrinth.com/data/x/versions/$id/src.jar',
      'primary': false,
      'hashes': {},
    },
  ],
};

/// Mirrors the screenshot from the request (newest first).
List<Map<String, dynamic>> screenshotVersions() {
  final d2 = DateTime.utc(2026, 9, 15), d3 = DateTime.utc(2026, 8, 10);
  return [
    for (final l in ['fabric', 'neoforge', 'forge'])
      mrVersion('${l}263', l, ['26.3'], 'MC26.3-v1.3.0', d2.add(const Duration(hours: 3))),
    for (final l in ['fabric', 'neoforge', 'forge'])
      mrVersion('${l}262', l, ['26.2'], 'MC26.2-v1.2.3', d2.add(const Duration(hours: 2))),
    for (final l in ['fabric', 'neoforge', 'forge'])
      mrVersion('${l}261', l, ['26.1', '26.1.1', '26.1.2'], 'MC26.1-v1.1.3', d2.add(const Duration(hours: 1))),
    for (final l in ['fabric', 'neoforge', 'forge']) mrVersion('${l}12111', l, ['1.21.11'], 'MC1.21.11-v1.0.3', d2),
    mrVersion('fabric262old', 'fabric', ['26.2'], 'MC26.2-v1.2.2', d3),
  ];
}

TrackedSource modSource() => TrackedSource(id: 'm', kind: SourceKind.modrinth, ref: 'examplemod', name: 'Example Mod');

void main() {
  group('latest per loader & game version (screenshot scenario)', () {
    test('downloads newest per loader+version and ignores the older 26.2 build', () {
      final rel = ModrinthSource.parseVersions(screenshotVersions(), 'examplemod');
      final plan = planSync(modSource(), rel, platform: linux);
      final ids = plan.downloads.map((d) => d.release.id).toSet();
      expect(ids, isNot(contains('fabric262old')));
      expect(ids, containsAll(['fabric263', 'neoforge263', 'forge263', 'fabric262', 'neoforge262', 'forge262']));
      expect(ids.length, 12);
      // Only primary jars (no -sources.jar).
      expect(plan.downloads.every((d) => d.files.length == 1 && d.files.single.primary), isTrue);
      final folders = plan.downloads.map((d) => d.folder).toSet();
      expect(folders, containsAll(['26.3/fabric', '26.2/forge', '26.1-26.1.2/neoforge', '1.21.11/fabric']));
    });

    test('loader filter and newest-N game versions', () {
      final s = modSource()
        ..loaders = ['fabric']
        ..gameVersionLimit = 2;
      final rel = ModrinthSource.parseVersions(screenshotVersions(), 'examplemod');
      final plan = planSync(s, rel, platform: linux);
      expect(plan.downloads.map((d) => d.release.id).toSet(), {'fabric263', 'fabric262'});
    });

    test('a newer build replaces the slot and the old file is deleted', () {
      final s = modSource();
      final rel = ModrinthSource.parseVersions(screenshotVersions(), 'examplemod');
      final first = planSync(s, rel, platform: linux);
      s.downloads = [
        for (final d in first.downloads)
          DownloadRecord(
            slot: d.slot,
            releaseId: d.release.id,
            version: d.release.version,
            publishedAt: d.release.publishedAt,
            files: ['/x/${d.folder}/${d.files.first.name}'],
            downloadedAt: DateTime.now(),
          ),
      ];
      expect(planSync(s, rel, platform: linux).isEmpty, isTrue);
      final updated = ModrinthSource.parseVersions([
        mrVersion('fabric264', 'fabric', ['26.3'], 'MC26.3-v1.3.1', DateTime.utc(2026, 11, 1)),
        ...screenshotVersions(),
      ], 'examplemod');
      final plan = planSync(s, updated, platform: linux);
      expect(plan.downloads.single.release.id, 'fabric264');
      expect(plan.delete.single.releaseId, 'fabric263');
      s.keepOld = true;
      final keep = planSync(s, updated, platform: linux);
      expect(keep.delete, isEmpty);
      expect(keep.archive.single.releaseId, 'fabric263');
    });

    test('preferStable falls back to beta only when no release exists', () {
      final rel = ModrinthSource.parseVersions([
        mrVersion('b', 'fabric', ['26.4'], 'beta', DateTime.utc(2026, 11, 2), type: 'beta'),
        mrVersion('r', 'fabric', ['26.4'], 'rel', DateTime.utc(2026, 11, 1)),
        mrVersion('a', 'fabric', ['26.5'], 'alpha', DateTime.utc(2026, 11, 3), type: 'alpha'),
      ], 'x');
      final plan = planSync(modSource(), rel, platform: linux);
      expect(plan.downloads.map((d) => d.release.id).toSet(), {'r', 'a'});
    });

    test('empty API result never deletes anything', () {
      final s = modSource()
        ..downloads = [
          DownloadRecord(
            slot: 'slot:fabric|1',
            releaseId: 'z',
            version: '',
            publishedAt: null,
            files: ['/a'],
            downloadedAt: DateTime.now(),
          ),
        ];
      expect(planSync(s, [], platform: linux).isEmpty, isTrue);
    });
  });

  group('GitHub modes', () {
    RemoteRelease gh(String id, DateTime d, {bool pre = false, List<String>? files}) => RemoteRelease(
      id: id,
      version: 'v$id',
      title: id,
      publishedAt: d,
      channel: pre ? ReleaseChannel.beta : ReleaseChannel.release,
      files: [
        for (final f in files ?? ['app-$id-linux-x64.AppImage', 'app-$id.apk', 'app-$id-win-x64.exe'])
          RemoteFile(name: f, urls: ['https://x/$f']),
      ],
    );
    final rels = [
      gh('3', DateTime.utc(2026, 3), pre: true),
      gh('2', DateTime.utc(2026, 2)),
      gh('1', DateTime.utc(2026, 1)),
    ];

    test('latest + platform files', () {
      final s = TrackedSource(id: 'g', kind: SourceKind.github, ref: 'a/b', name: 'B', onlyPlatformFiles: true);
      final plan = planSync(s, rels, platform: linux);
      expect(plan.downloads.single.release.id, '2');
      expect(plan.downloads.single.files.map((f) => f.name), ['app-2-linux-x64.AppImage']);
    });

    test('all releases downloads everything incl. prereleases when allowed', () {
      final s = TrackedSource(
        id: 'g',
        kind: SourceKind.github,
        ref: 'a/b',
        name: 'B',
        mode: TrackMode.allReleases,
        channels: {ReleaseChannel.release, ReleaseChannel.beta},
      );
      final plan = planSync(s, rels, platform: linux);
      expect(plan.downloads.map((d) => d.release.id), ['3', '2', '1']);
      expect(plan.downloads.first.files.length, 3);
    });

    test('new releases: baseline, then only newer ones; keep or delete old', () {
      final s = TrackedSource(
        id: 'g',
        kind: SourceKind.github,
        ref: 'a/b',
        name: 'B',
        mode: TrackMode.newReleases,
        keepOld: true,
      );
      final p1 = planSync(s, rels, platform: linux);
      expect(p1.downloads.single.release.id, '2');
      s.baseline = p1.newBaseline;
      s.downloads = [
        DownloadRecord(
          slot: p1.downloads.single.slot,
          releaseId: '2',
          version: 'v2',
          publishedAt: DateTime.utc(2026, 2),
          files: ['/f2'],
          downloadedAt: DateTime.now(),
        ),
      ];
      final newer = [gh('5', DateTime.utc(2026, 5)), gh('4', DateTime.utc(2026, 4)), ...rels];
      final p2 = planSync(s, newer, platform: linux);
      expect(p2.downloads.map((d) => d.release.id), ['5', '4']);
      expect(p2.delete, isEmpty);
      s.keepOld = false;
      final p3 = planSync(s, newer, platform: linux);
      expect(p3.downloads.map((d) => d.release.id), ['5']);
      expect(p3.delete.single.releaseId, '2');
    });
  });

  group('platform matching', () {
    final names = [
      'App-1.0-arm64-v8a.apk',
      'App-1.0-armeabi-v7a.apk',
      'App-1.0-x86_64.apk',
      'App-1.0.apk',
      'App-Setup-1.0-x64.exe',
      'App-1.0-windows-arm64.zip',
      'App-1.0-win-x64.zip',
      'App-1.0-universal.dmg',
      'App-1.0-x86_64.AppImage',
      'App-1.0-aarch64.AppImage',
      'app_1.0_amd64.deb',
      'App-1.0-linux-x64.tar.gz',
      'App-1.0-macos-x64.tar.gz',
      'checksums.sha256',
      'App-1.0.ipa',
      'source.tar.gz',
    ];
    test('android arm64 prefers the native split', () {
      expect(pickPlatformFiles(names, const PlatformInfo('android', 'arm64')), ['App-1.0-arm64-v8a.apk']);
    });
    test('windows x64', () {
      expect(pickPlatformFiles(names, const PlatformInfo('windows', 'x64')), [
        'App-Setup-1.0-x64.exe',
        'App-1.0-win-x64.zip',
      ]);
    });
    test('linux x64', () {
      expect(pickPlatformFiles(names, linux), [
        'App-1.0-x86_64.AppImage',
        'app_1.0_amd64.deb',
        'App-1.0-linux-x64.tar.gz',
      ]);
    });
    test('macos arm64', () {
      expect(pickPlatformFiles(names, const PlatformInfo('macos', 'arm64')), ['App-1.0-universal.dmg']);
    });
    test('ios', () {
      expect(pickPlatformFiles(names, const PlatformInfo('ios', 'arm64')), ['App-1.0.ipa']);
    });
  });

  group('links', () {
    test('parses all supported forms', () {
      expect('${parseSourceLink('https://github.com/ImranR98/Obtainium/releases')}', 'github:ImranR98/Obtainium');
      expect('${parseSourceLink('github.com/a/b.git')}', 'github:a/b');
      expect('${parseSourceLink('owner/repo')}', 'github:owner/repo');
      expect('${parseSourceLink('https://modrinth.com/mod/sodium/versions')}', 'modrinth:sodium');
      expect('${parseSourceLink('https://www.curseforge.com/minecraft/mc-mods/jei/files')}', 'curseforge:jei');
      expect('${parseSourceLink('cf:238222')}', 'curseforge:238222');
      expect('${parseSourceLink('https://someone.itch.io/cool-game')}', 'itchio:someone/cool-game');
      expect('${parseSourceLink('itch:123')}', 'itchio:123');
      expect('${parseSourceLink('https://example.com/x')}', 'web:https://example.com/x');
      expect('${parseSourceLink('https://gitlab.com/group/sub/proj/-/releases')}', 'gitlab:gitlab.com/group/sub/proj');
      expect('${parseSourceLink('https://codeberg.org/owner/repo/releases')}', 'forgejo:codeberg.org/owner/repo');
      expect('${parseSourceLink('https://f-droid.org/en/packages/org.fdroid.fdroid/')}', 'fdroid:org.fdroid.fdroid');
      expect(
        '${parseSourceLink('https://git.example.org/a/b', forceKind: SourceKind.forgejo)}',
        'forgejo:git.example.org/a/b',
      );
      expect(parseSourceLink('http://insecure.example/x'), isNull);
    });
  });

  group('CurseForge / itch.io parsing', () {
    test('CurseForge splits loaders from game versions and builds CDN fallback', () {
      final r = CurseForgeSource.parseFiles([
        {
          'id': 5123456,
          'displayName': 'Mod 1.0 Fabric',
          'fileName': 'mod 1.0.jar',
          'releaseType': 1,
          'fileDate': '2026-10-01T00:00:00Z',
          'downloadUrl': null,
          'fileLength': 5,
          'hashes': [
            {'value': 'ABC', 'algo': 1},
          ],
          'gameVersions': ['1.21.11', 'Fabric', 'NeoForge', 'Client', 'Java 21', '26.1-Snapshot-3'],
        },
      ], '1');
      expect(r.single.loaders, ['fabric', 'neoforge']);
      expect(r.single.gameVersions, ['1.21.11', '26.1-Snapshot-3']);
      expect(r.single.files.single.urls.first, 'https://mediafilez.forgecdn.net/files/5123/456/mod%201.0.jar');
      expect(r.single.files.single.hashes['sha1'], 'abc');
    });

    test('itch.io release id changes when an upload changes', () {
      List<Map<String, dynamic>> ups(String build) => [
        {
          'id': 1,
          'filename': 'game-win.zip',
          'size': 3,
          'traits': ['p_windows'],
          'build_id': build,
          'updated_at': '2026-10-01T10:00:00Z',
        },
        {'id': 2, 'filename': 'game-linux.zip', 'size': 3, 'p_linux': true, 'updated_at': '2026-10-02T10:00:00Z'},
      ];
      final a = ItchSource.buildRelease('a/b', ups('1'), apiBase: 'https://api.itch.io', apiKey: 'k')!;
      final b = ItchSource.buildRelease('a/b', ups('2'), apiBase: 'https://api.itch.io', apiKey: 'k')!;
      expect(a.id, isNot(b.id));
      expect(a.files.first.urls.single, 'https://api.itch.io/uploads/1/download?api_key=k');
      final s = TrackedSource(id: 'i', kind: SourceKind.itchio, ref: '1', name: 'G', onlyPlatformFiles: true);
      expect(planSync(s, [a], platform: linux).downloads.single.files.map((f) => f.name), ['game-linux.zip']);
    });
  });

  test('engine end-to-end: download, verify, replace, custom folder', () async {
    final tmp = await Directory.systemTemp.createTemp('getterx');
    final custom = p.join(tmp.path, 'D', 'lol', 'here');
    var versions = screenshotVersions();
    final client = MockClient((req) async {
      final u = req.url.toString();
      if (u.contains('/v2/project/examplemod/version')) return http.Response(jsonEncode(versions), 200);
      if (u.contains('/v2/project/examplemod')) {
        return http.Response(jsonEncode({'slug': 'examplemod', 'title': 'Example Mod', 'project_type': 'mod'}), 200);
      }
      final id = req.url.pathSegments[req.url.pathSegments.length - 2];
      return http.Response.bytes(utf8.encode('jar:$id').toList(), 200);
    });
    final store = ConfigStore(Directory(p.join(tmp.path, 'data')));
    await store.load();
    final engine = Engine(store, client: client, platform: linux, defaultDownloadRoot: p.join(tmp.path, 'dl'));
    final s = await engine.createFromLink('https://modrinth.com/mod/examplemod');
    s.downloadDir = custom;
    s.loaders = ['fabric'];
    await store.saveSource(s);

    // Hash mismatch on purpose for one file: size 10 in fixture vs real size -> fix sizes.
    for (final v in versions) {
      for (final f in (v['files'] as List).cast<Map>()) {
        f['size'] = utf8.encode('jar:${v['id']}').length;
      }
    }
    final r1 = await engine.check(s.id);
    expect(r1.errors, isEmpty);
    expect(r1.downloaded.length, 6); // 26.3, 26.2, 26.1/26.1.1/26.1.2 (one file), 1.21.11
    expect(File(p.join(custom, '26.3', 'fabric', 'fabric_MC26.3-v1.3.0.jar')).existsSync(), isTrue);
    expect(File(p.join(custom, '26.1-26.1.2', 'fabric', 'fabric_MC26.1-v1.1.3.jar')).existsSync(), isTrue);
    expect(Directory(p.join(custom, '26.2', 'forge')).existsSync(), isFalse);

    final again = await engine.check(s.id);
    expect(again.downloaded, isEmpty);

    final nv = mrVersion('fabric264', 'fabric', ['26.3'], 'MC26.3-v1.3.1', DateTime.utc(2026, 11, 1));
    (nv['files'] as List).cast<Map>().first['size'] = utf8.encode('jar:fabric264').length;
    versions = [nv, ...versions];
    final r3 = await engine.check(s.id);
    expect(r3.downloaded.single.version, 'MC26.3-v1.3.1');
    expect(r3.deletedFiles, 1);
    expect(File(p.join(custom, '26.3', 'fabric', 'fabric_MC26.3-v1.3.0.jar')).existsSync(), isFalse);
    expect(File(p.join(custom, '26.3', 'fabric', 'fabric_MC26.3-v1.3.1.jar')).existsSync(), isTrue);

    // Persisted.
    final reloaded = ConfigStore(Directory(p.join(tmp.path, 'data')));
    await reloaded.load();
    expect(reloaded.config.sources.single.downloadDir, custom);
    await tmp.delete(recursive: true);
  });

  group('file choice', () {
    test('patternForFiles survives version bumps but keeps arch', () {
      final re = RegExp(patternForFiles(['App-1.2.3-win-x64.exe', 'app_v2.0_amd64.deb']));
      expect(re.hasMatch('App-1.10.0-win-x64.exe'), isTrue);
      expect(re.hasMatch('App-1.10.0-win-x86.exe'), isFalse);
      expect(re.hasMatch('app_v3.1_amd64.deb'), isTrue);
      expect(re.hasMatch('App-1.10.0-win-x64.zip'), isFalse);
    });
    test('file types and version regex', () {
      final s = TrackedSource(
        id: 'g',
        kind: SourceKind.github,
        ref: 'a/b',
        name: 'B',
        mode: TrackMode.allReleases,
        fileTypes: ['exe'],
        versionRegex: r'^v2',
      );
      RemoteRelease r(String v) => RemoteRelease(
        id: v,
        version: v,
        title: v,
        publishedAt: DateTime.utc(2026),
        channel: ReleaseChannel.release,
        files: [
          RemoteFile(name: 'a-$v.exe', urls: const ['https://x/a']),
          RemoteFile(name: 'a-$v.zip', urls: const ['https://x/b']),
        ],
      );
      final plan = planSync(s, [r('v2.1'), r('v1.9')], platform: linux);
      expect(plan.downloads.single.release.version, 'v2.1');
      expect(plan.downloads.single.files.map((f) => f.name), ['a-v2.1.exe']);
      expect(fileExtension('x.tar.gz'), 'tar.gz');
      expect(fileExtension('X.AppImage'), 'appimage');
    });
  });

  test('website: groups links by version and picks the newest', () {
    const html = '''
      <a href="/dl/Tool-1.9.0-win-x64.exe">old</a>
      <a href="/dl/Tool-1.10.2-win-x64.exe">Download for Windows</a>
      <a href='https://cdn.example.com/Tool-1.10.2-linux-x64.AppImage?x=1&amp;y=2'>Linux</a>
      <a href="/about">About</a> <a href="http://insecure/Tool-9.9.exe">bad</a>
      <a href="Tool-latest.zip">nightly</a>''';
    final s = TrackedSource(id: 'w', kind: SourceKind.web, ref: 'https://tool.example.com/downloads/', name: 'Tool');
    final rel = WebSource.parsePage(s, Uri.parse(s.ref), html);
    expect(rel.first.version, '1.10.2');
    expect(rel.first.files.map((f) => f.urls.single), [
      'https://tool.example.com/dl/Tool-1.10.2-win-x64.exe',
      'https://cdn.example.com/Tool-1.10.2-linux-x64.AppImage?x=1&y=2',
    ]);
    expect(rel.map((r) => r.version), ['1.10.2', '1.9.0', 'unversioned']);
    final plan = planSync(s..onlyPlatformFiles = true, rel, platform: linux);
    expect(plan.downloads.single.files.single.name, 'Tool-1.10.2-linux-x64.AppImage');
  });
}
