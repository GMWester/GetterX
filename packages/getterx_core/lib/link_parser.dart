import 'models.dart';

class ParsedLink {
  final SourceKind kind;
  final String ref;
  const ParsedLink(this.kind, this.ref);
  @override
  String toString() => '${kind.name}:$ref';
}

/// Accepts:
///  - https://github.com/owner/repo[/anything], github.com/owner/repo, owner/repo
///  - https://modrinth.com/mod/slug (also plugin, datapack, shader, resourcepack, modpack, project)
///  - https://www.curseforge.com/minecraft/mc-mods/slug (any class), curseforge:12345, cf:slug
///  - https://author.itch.io/game, itch:author/game, itch:123456 (game id)
///  - modrinth:slug, mr:slug, gh:owner/repo
ParsedLink? parseSourceLink(String input, {SourceKind? forceKind}) {
  var s = input.trim();
  if (s.isEmpty) return null;
  final prefix = RegExp(
    r'^(gh|github|mr|modrinth|cf|curseforge|itch|itchio|gitlab|gl|forgejo|gitea|codeberg|fdroid|izzy|izzyondroid|sf|sourceforge|hangar|spigot|thunderstore|ts|bitbucket|bb|pypi|web|url):(.+)$',
    caseSensitive: false,
  ).firstMatch(s);
  if (prefix != null) {
    final k = switch (prefix[1]!.toLowerCase()) {
      'gh' || 'github' => SourceKind.github,
      'mr' || 'modrinth' => SourceKind.modrinth,
      'itch' || 'itchio' => SourceKind.itchio,
      'gitlab' || 'gl' => SourceKind.gitlab,
      'forgejo' || 'gitea' => SourceKind.forgejo,
      'codeberg' => SourceKind.forgejo,
      'fdroid' => SourceKind.fdroid,
      'izzy' || 'izzyondroid' => SourceKind.izzyondroid,
      'sf' || 'sourceforge' => SourceKind.sourceforge,
      'hangar' => SourceKind.hangar,
      'spigot' => SourceKind.spigot,
      'thunderstore' || 'ts' => SourceKind.thunderstore,
      'bitbucket' || 'bb' => SourceKind.bitbucket,
      'pypi' => SourceKind.pypi,
      'web' || 'url' => SourceKind.web,
      _ => SourceKind.curseforge,
    };
    if (prefix[1]!.toLowerCase() == 'codeberg') return _clean(k, 'codeberg.org/${prefix[2]}');
    if (k == SourceKind.web || k == SourceKind.gitlab || k == SourceKind.forgejo) {
      return parseSourceLink(prefix[2]!, forceKind: k) ?? _clean(k, prefix[2]!);
    }
    return _clean(k, prefix[2]!);
  }
  if (!s.contains('://')) {
    if (RegExp(
      r'^(www\.)?((github|modrinth|curseforge|gitlab)\.com|codeberg\.org|f-droid\.org|sourceforge\.net|hangar\.papermc\.io|spigotmc\.org|thunderstore\.io|bitbucket\.org|pypi\.org|[\w-]+\.itch\.io)/',
      caseSensitive: false,
    ).hasMatch(s)) {
      s = 'https://$s';
    }
  }
  final uri = Uri.tryParse(s);
  if (uri != null && uri.host.isNotEmpty) {
    final host = uri.host.toLowerCase().replaceFirst('www.', '');
    final seg = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    // Self-hosted forges / explicit website when the user picked the type.
    if (forceKind == SourceKind.web) return ParsedLink(SourceKind.web, uri.toString());
    if (forceKind == SourceKind.forgejo && seg.length >= 2) {
      return _clean(SourceKind.forgejo, '${uri.host}/${seg[0]}/${seg[1]}');
    }
    if (forceKind == SourceKind.gitlab && seg.length >= 2) {
      final dash = seg.indexOf('-');
      return _clean(SourceKind.gitlab, '${uri.host}/${(dash < 0 ? seg : seg.sublist(0, dash)).join('/')}');
    }
    if (host == 'gitlab.com' && seg.length >= 2) {
      final dash = seg.indexOf('-');
      return _clean(SourceKind.gitlab, 'gitlab.com/${(dash < 0 ? seg : seg.sublist(0, dash)).join('/')}');
    }
    if (host == 'codeberg.org' && seg.length >= 2) {
      return _clean(SourceKind.forgejo, 'codeberg.org/${seg[0]}/${seg[1]}');
    }
    if (host == 'sourceforge.net' && seg.length >= 2 && seg[0] == 'projects') {
      // /projects/<name>[/files/<folder...>]
      final fi = seg.indexOf('files');
      final folder = fi >= 0 ? seg.sublist(fi + 1).where((e) => e != 'download' && e != 'latest').join('/') : '';
      return _clean(SourceKind.sourceforge, folder.isEmpty ? seg[1] : '${seg[1]}/$folder');
    }
    if (host == 'hangar.papermc.io' && seg.length >= 2) return _clean(SourceKind.hangar, seg[1]);
    if (host == 'spigotmc.org' && seg.length >= 2 && seg[0] == 'resources') {
      // /resources/<name>.<id>/
      final id = RegExp(r'(\d+)$').firstMatch(seg[1])?[1];
      if (id != null) return _clean(SourceKind.spigot, id);
    }
    if (host == 'thunderstore.io') {
      // /c/<community>/p/<namespace>/<name>/  or /package/<namespace>/<name>/
      final pi = seg.contains('p') ? seg.indexOf('p') : seg.indexOf('package');
      if (pi >= 0 && pi + 2 < seg.length) return _clean(SourceKind.thunderstore, '${seg[pi + 1]}/${seg[pi + 2]}');
    }
    if (host == 'bitbucket.org' && seg.length >= 2) return _clean(SourceKind.bitbucket, '${seg[0]}/${seg[1]}');
    if (host == 'pypi.org' && seg.length >= 2 && seg[0] == 'project') return _clean(SourceKind.pypi, seg[1]);
    if (host == 'apt.izzysoft.de') {
      // https://apt.izzysoft.de/fdroid/index/apk/<package>
      final i = seg.indexOf('apk');
      if (i >= 0 && i + 1 < seg.length) return _clean(SourceKind.izzyondroid, seg[i + 1]);
    }
    if (host == 'f-droid.org') {
      final i = seg.indexOf('packages');
      if (i >= 0 && i + 1 < seg.length) return _clean(SourceKind.fdroid, seg[i + 1]);
    }
    if (host.endsWith('.itch.io') && host != 'www.itch.io' && seg.isNotEmpty) {
      // https://author.itch.io/game -> author/game
      return _clean(SourceKind.itchio, '${host.split('.').first}/${seg[0]}');
    }
    if (host == 'github.com' && seg.length >= 2) {
      return _clean(SourceKind.github, '${seg[0]}/${seg[1]}');
    }
    if (host == 'modrinth.com' && seg.length >= 2) {
      return _clean(SourceKind.modrinth, seg[1]);
    }
    if (host == 'curseforge.com' || host == 'legacy.curseforge.com') {
      // /minecraft/mc-mods/slug
      if (seg.length >= 3) return _clean(SourceKind.curseforge, seg[2]);
    }
    // Anything else: track it as a generic website / direct file.
    if (uri.scheme == 'https') return ParsedLink(SourceKind.web, uri.toString());
    return null;
  }
  // Bare reference.
  if (forceKind != null) return _clean(forceKind, s);
  if (RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(s)) return _clean(SourceKind.github, s);
  return null;
}

ParsedLink _clean(SourceKind k, String ref) {
  var r = ref.trim();
  if (k == SourceKind.github || k == SourceKind.gitlab || k == SourceKind.forgejo) {
    r = r.replaceAll(RegExp(r'\.git$'), '');
  }
  return ParsedLink(k, r);
}
