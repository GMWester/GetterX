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
  final prefix = RegExp(r'^(gh|github|mr|modrinth|cf|curseforge|itch|itchio):(.+)$', caseSensitive: false)
      .firstMatch(s);
  if (prefix != null) {
    final k = switch (prefix[1]!.toLowerCase()) {
      'gh' || 'github' => SourceKind.github,
      'mr' || 'modrinth' => SourceKind.modrinth,
      'itch' || 'itchio' => SourceKind.itchio,
      _ => SourceKind.curseforge,
    };
    return _clean(k, prefix[2]!);
  }
  if (!s.contains('://')) {
    if (RegExp(r'^(www\.)?(github|modrinth|curseforge)\.com/', caseSensitive: false).hasMatch(s)) {
      s = 'https://$s';
    }
  }
  final uri = Uri.tryParse(s);
  if (uri != null && uri.host.isNotEmpty) {
    final host = uri.host.toLowerCase().replaceFirst('www.', '');
    final seg = uri.pathSegments.where((e) => e.isNotEmpty).toList();
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
    return null;
  }
  // Bare reference.
  if (forceKind != null) return _clean(forceKind, s);
  if (RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(s)) return _clean(SourceKind.github, s);
  return null;
}

ParsedLink _clean(SourceKind k, String ref) {
  var r = ref.trim();
  if (k == SourceKind.github) r = r.replaceAll(RegExp(r'\.git$'), '');
  return ParsedLink(k, r);
}
