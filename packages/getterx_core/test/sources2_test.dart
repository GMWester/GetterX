import 'dart:convert';

import 'package:getterx_core/backup.dart';
import 'package:getterx_core/discovery.dart';
import 'package:getterx_core/link_parser.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/platform_match.dart';
import 'package:getterx_core/search.dart';
import 'package:getterx_core/selector.dart';
import 'package:getterx_core/sources/hangar.dart';
import 'package:getterx_core/sources/pypi.dart';
import 'package:getterx_core/sources/sourceforge.dart';
import 'package:getterx_core/sources/spigot.dart';
import 'package:getterx_core/virustotal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const linux = PlatformInfo('linux', 'x64');

void main() {
  test('links for the new sources', () {
    expect('${parseSourceLink('https://sourceforge.net/projects/keepass/')}', 'sourceforge:keepass');
    expect('${parseSourceLink('https://sourceforge.net/projects/x/files/Stable/2.0/')}', 'sourceforge:x/Stable/2.0');
    expect('${parseSourceLink('https://hangar.papermc.io/EssentialsX/Essentials')}', 'hangar:Essentials');
    expect('${parseSourceLink('https://www.spigotmc.org/resources/luckperms.28140/')}', 'spigot:28140');
    expect(
      '${parseSourceLink('https://thunderstore.io/c/lethal-company/p/BepInEx/BepInExPack/')}',
      'thunderstore:BepInEx/BepInExPack',
    );
    expect('${parseSourceLink('https://bitbucket.org/ws/repo/downloads/')}', 'bitbucket:ws/repo');
    expect('${parseSourceLink('https://pypi.org/project/requests/')}', 'pypi:requests');
    expect(
      '${parseSourceLink('https://apt.izzysoft.de/fdroid/index/apk/com.example.app')}',
      'izzyondroid:com.example.app',
    );
  });

  test('SourceForge feed: folders become releases, md5 kept', () {
    const xml = '''<rss><channel><title>Cool Tool from SourceForge.net</title>
<item><title><![CDATA[/2.1/cooltool-2.1-win64.exe]]></title><link>https://sourceforge.net/projects/cooltool/files/2.1/cooltool-2.1-win64.exe/download</link>
<pubDate>Tue, 03 Nov 2026 10:00:00 UT</pubDate><media:content url="x" filesize="1234"><media:hash algo="md5">0123456789abcdef0123456789ABCDEF</media:hash></media:content></item>
<item><title><![CDATA[/2.1/cooltool-2.1.tar.gz]]></title><link>https://sourceforge.net/projects/cooltool/files/2.1/cooltool-2.1.tar.gz/download</link><pubDate>Tue, 03 Nov 2026 10:01:00 UT</pubDate></item>
<item><title><![CDATA[/2.0/cooltool-2.0-win64.exe]]></title><link>https://sourceforge.net/projects/cooltool/files/2.0/cooltool-2.0-win64.exe/download</link><pubDate>Mon, 01 Jun 2026 10:00:00 UT</pubDate></item>
</channel></rss>''';
    final r = SourceForgeSource.parseFeed(xml, 'cooltool');
    expect(r.map((e) => e.version), ['2.1', '2.0']);
    expect(r.first.files.length, 2);
    expect(r.first.files.first.hashes['md5'], '0123456789abcdef0123456789abcdef');
    expect(r.first.files.first.size, 1234);
  });

  test('Hangar: one release per platform with game versions', () {
    final r = HangarSource.parseVersions([
      {
        'name': '2.5.0',
        'createdAt': '2026-10-01T00:00:00Z',
        'channel': {'name': 'Release'},
        'downloads': {
          'PAPER': {
            'fileInfo': {'name': 'Plugin-2.5.0.jar', 'sizeBytes': 10, 'sha256Hash': 'AB'},
            'downloadUrl': 'https://hangar.papermc.io/api/v1/projects/p/versions/2.5.0/PAPER/download',
          },
          'VELOCITY': {'externalUrl': 'https://example.com/velocity.jar', 'fileInfo': null},
        },
        'platformDependencies': {
          'PAPER': ['1.21.10', '1.21.11'],
          'VELOCITY': ['3.4'],
        },
      },
    ], 'p');
    expect(r.map((e) => e.loaders.single), ['paper', 'velocity']);
    expect(r.first.gameVersions, ['1.21.10', '1.21.11']);
    expect(r.first.files.single.hashes['sha256'], 'ab');
    final s = TrackedSource(id: 'h', kind: SourceKind.hangar, ref: 'p', name: 'P');
    expect(s.mode, TrackMode.latestPerLoaderAndGameVersion);
    expect(planSync(s, r, platform: linux).downloads.length, 3);
  });

  test('Spigot latest; premium resources are refused', () {
    final rel = SpigotSource.buildLatest(
      {
        'name': 'LuckPerms',
        'file': {'type': '.jar'},
        'testedVersions': ['1.21'],
      },
      [
        {'id': 9, 'name': '5.4', 'releaseDate': 1767225600},
      ],
      '28140',
    )!;
    expect(rel.files.single.urls.single, 'https://api.spiget.org/v2/resources/28140/download');
    expect(rel.files.single.name, 'LuckPerms-5.4.jar');
    expect(() => SpigotSource.buildLatest({'premium': true}, [], '1'), throwsA(anything));
  });

  test('PyPI: yanked files skipped, pre-releases are beta', () {
    final r = PyPiSource.parse({
      '1.0': [
        {
          'filename': 'p-1.0.tar.gz',
          'url': 'https://files.pythonhosted.org/p-1.0.tar.gz',
          'upload_time_iso_8601': '2026-01-01T00:00:00Z',
          'digests': {'sha256': 'aa'},
        },
      ],
      '2.0rc1': [
        {'filename': 'p-2.0rc1.tar.gz', 'url': 'https://x/p.tgz', 'upload_time_iso_8601': '2026-02-01T00:00:00Z'},
      ],
      '0.9': [
        {'filename': 'p-0.9.tar.gz', 'url': 'https://x/old.tgz', 'yanked': true},
      ],
    }, 'p');
    expect(r.map((e) => e.version), ['2.0rc1', '1.0']);
    expect(r.first.channel, ReleaseChannel.beta);
  });

  test('track-only never downloads; skipped version is ignored', () {
    RemoteRelease rel(String v, int day) => RemoteRelease(
      id: v,
      version: v,
      title: v,
      publishedAt: DateTime.utc(2026, 1, day),
      channel: ReleaseChannel.release,
      files: [
        RemoteFile(name: 'a-$v.AppImage', urls: const ['https://x/a']),
      ],
    );
    final s = TrackedSource(id: 'g', kind: SourceKind.github, ref: 'a/b', name: 'B', mode: TrackMode.trackOnly);
    final p = planSync(s, [rel('2.0', 2), rel('1.0', 1)], platform: linux);
    expect(p.downloads, isEmpty);
    expect(p.newestVersion, '2.0');
    final s2 = TrackedSource(id: 'g', kind: SourceKind.github, ref: 'a/b', name: 'B', skippedVersion: '2.0');
    expect(planSync(s2, [rel('2.0', 2), rel('1.0', 1)], platform: linux).downloads.single.release.version, '1.0');
  });

  test('search merges sources and survives a failing one', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'api.modrinth.com') {
        expect(req.url.queryParameters['facets'], '[["project_type:modpack"]]');
        return http.Response(
          jsonEncode({
            'hits': [
              {'slug': 'fabulously-optimized', 'title': 'Fabulously Optimized', 'project_type': 'modpack'},
            ],
          }),
          200,
        );
      }
      if (req.url.path.contains('/v1/mods/search')) {
        expect(req.url.queryParameters['classId'], '4471');
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 396246, 'name': 'Fabulously Optimized', 'classId': 4471},
            ],
          }),
          200,
        );
      }
      return http.Response('boom', 500);
    });
    final out = await Searcher(client).search('fabulously', type: ContentType.modpack);
    expect(out.results.map((r) => r.link), ['https://modrinth.com/modpack/fabulously-optimized', 'curseforge:396246']);
    expect(out.errors, isEmpty); // only Modrinth + CurseForge have modpacks
    final all = await Searcher(client).search('x');
    expect(all.errors.keys, containsAll([SourceKind.hangar, SourceKind.spigot, SourceKind.github]));
    expect(out.errors.containsKey(SourceKind.github), isFalse); // github has no modpacks, not queried
  });

  test('discovery: CurseForge mod found on Modrinth by SHA-1, plus source code link', () async {
    final client = MockClient((req) async {
      final u = req.url.toString();
      if (u.contains('/v1/mods/123')) {
        return http.Response(
          jsonEncode({
            'data': {
              'id': 123,
              'slug': 'cool',
              'name': 'Cool Mod',
              'links': {'sourceUrl': 'https://github.com/dev/cool'},
            },
          }),
          200,
        );
      }
      if (u.contains('/v2/version_file/abc')) return http.Response(jsonEncode({'project_id': 'P1'}), 200);
      if (u.contains('/v2/project/P1'))
        return http.Response(jsonEncode({'slug': 'cool-mod', 'title': 'Cool Mod', 'project_type': 'mod'}), 200);
      return http.Response('{}', 404);
    });
    final s = TrackedSource(id: 'c', kind: SourceKind.curseforge, ref: '123', name: 'Cool Mod');
    final alts = await Discovery(client).find(
      s,
      releases: [
        RemoteRelease(
          id: '1',
          version: '1',
          title: '1',
          publishedAt: null,
          channel: ReleaseChannel.release,
          files: [
            const RemoteFile(name: 'cool.jar', urls: ['https://x'], hashes: {'sha1': 'abc'}),
          ],
        ),
      ],
    );
    expect(alts.first.kind, SourceKind.modrinth);
    expect(alts.first.confidence, 3);
    expect(alts.map((a) => a.kind), contains(SourceKind.github));
  });

  test('discovery: Modrinth mod found on CurseForge by slug and name', () async {
    final client = MockClient((req) async {
      final u = req.url.toString();
      if (u.contains('api.modrinth.com/v2/project/sodium')) {
        return http.Response(
          jsonEncode({'slug': 'sodium', 'title': 'Sodium', 'source_url': 'https://github.com/CaffeineMC/sodium'}),
          200,
        );
      }
      if (u.contains('/v1/mods/search')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 394468, 'slug': 'sodium', 'name': 'Sodium'},
              {'id': 5, 'slug': 'other', 'name': 'Other'},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final alts = await Discovery(
      client,
    ).find(TrackedSource(id: 'm', kind: SourceKind.modrinth, ref: 'sodium', name: 'Sodium'));
    expect(alts.map((a) => a.link), containsAll(['curseforge:394468', 'https://github.com/CaffeineMC/sodium']));
    expect(alts.where((a) => a.link == 'curseforge:394468').single.reason, 'Same name and slug');
    expect(alts.any((a) => a.link == 'curseforge:5'), isFalse);
  });

  test('VirusTotal stats parsing', () {
    final r = VirusTotal.parse(
      '{"data":{"attributes":{"last_analysis_stats":{"malicious":2,"suspicious":1,"undetected":60,"harmless":0}}}}',
      'h',
    );
    expect(r.verdict, ScanVerdict.flagged);
    expect(r.engines, 63);
    expect(VirusTotal.parse('{"last_analysis_stats":{"malicious":0,"undetected":70}}', 'h').verdict, ScanVerdict.clean);
  });

  test('backup round trip without secrets or history; Obtainium import', () {
    final s =
        TrackedSource(id: 'a', kind: SourceKind.github, ref: 'o/r', name: 'R', categories: ['Tools'], pinned: true)
          ..downloads = [
            DownloadRecord(
              slot: 'latest',
              releaseId: '1',
              version: 'v1',
              publishedAt: null,
              files: ['/x'],
              downloadedAt: DateTime.now(),
            ),
          ];
    final text = exportBackup(AppSettings(), [s]);
    expect(text, isNot(contains('/x')));
    final back = parseBackup(text);
    expect(back.sources.single.categories, ['Tools']);
    expect(back.sources.single.pinned, isTrue);
    expect(linksFromText('{"apps":[{"url":"https://github.com/a/b"},{"url":"https://f-droid.org/packages/x"}]}'), [
      'https://github.com/a/b',
      'https://f-droid.org/packages/x',
    ]);
  });
}
