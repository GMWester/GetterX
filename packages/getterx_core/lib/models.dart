/// Data model shared by the app UI, the background worker and the CLI.
/// Pure Dart: must not import Flutter.
library;

enum SourceKind {
  github,
  modrinth,
  curseforge,
  itchio,
  gitlab,
  forgejo,
  fdroid,
  izzyondroid,
  sourceforge,
  hangar,
  spigot,
  thunderstore,
  bitbucket,
  pypi,
  web,
}

/// How a tracked source decides what to download.
enum TrackMode {
  /// Obtainium-style: keep only the newest release (one folder).
  latest,

  /// Download every release that appears after tracking started
  /// (the newest existing release is downloaded on the first check).
  newReleases,

  /// Download every release that has ever been published.
  allReleases,

  /// Mods: newest file for every (mod loader x game version) combination.
  latestPerLoaderAndGameVersion,

  /// Only watch for new versions (notify), never download.
  trackOnly,
}

enum ReleaseChannel { release, beta, alpha }

String trackModeLabel(TrackMode m) => switch (m) {
  TrackMode.latest => 'Latest only (auto-update)',
  TrackMode.newReleases => 'Every new release from now on',
  TrackMode.allReleases => 'Every release ever (full archive)',
  TrackMode.latestPerLoaderAndGameVersion => 'Latest per mod loader & game version',
  TrackMode.trackOnly => 'Track only (notify, no download)',
};

String sourceKindLabel(SourceKind k) => switch (k) {
  SourceKind.github => 'GitHub',
  SourceKind.modrinth => 'Modrinth',
  SourceKind.curseforge => 'CurseForge',
  SourceKind.itchio => 'itch.io',
  SourceKind.gitlab => 'GitLab',
  SourceKind.forgejo => 'Codeberg / Forgejo / Gitea',
  SourceKind.fdroid => 'F-Droid',
  SourceKind.izzyondroid => 'IzzyOnDroid',
  SourceKind.sourceforge => 'SourceForge',
  SourceKind.hangar => 'Hangar (PaperMC)',
  SourceKind.spigot => 'SpigotMC',
  SourceKind.thunderstore => 'Thunderstore',
  SourceKind.bitbucket => 'Bitbucket',
  SourceKind.pypi => 'PyPI',
  SourceKind.web => 'Website',
};

class RemoteFile {
  final String name;

  /// Download URLs, tried in order (mirrors).
  final List<String> urls;
  final int? size;

  /// Lower-case algorithm name (sha1, sha256, sha512, md5) -> hex digest.
  final Map<String, String> hashes;
  final bool primary;

  /// Extra request headers (e.g. auth for private GitHub assets). Dropped
  /// automatically when a download redirects to another host.
  final Map<String, String> headers;

  /// True for GitHub auto-generated source archives.
  final bool isSourceArchive;

  /// Platforms declared by the source (itch.io): windows, macos, linux, android.
  /// Empty = unknown, guessed from the file name.
  final Set<String> platforms;

  const RemoteFile({
    required this.name,
    required this.urls,
    this.size,
    this.hashes = const {},
    this.primary = false,
    this.isSourceArchive = false,
    this.platforms = const {},
    this.headers = const {},
  });
}

class RemoteRelease {
  /// Stable unique id within the source (release id, Modrinth version id, CF file id).
  final String id;
  final String version;
  final String title;
  final DateTime? publishedAt;
  final ReleaseChannel channel;

  /// Lower-case loader ids (fabric, forge, neoforge, quilt, ...). Empty = not applicable.
  final List<String> loaders;

  /// Game versions (e.g. 1.21.11, 26.3). Empty = not applicable.
  final List<String> gameVersions;
  final List<RemoteFile> files;
  final String? pageUrl;

  /// Position in the API response; used as a tie-breaker / when there is no date.
  final int order;

  const RemoteRelease({
    required this.id,
    required this.version,
    required this.title,
    required this.publishedAt,
    required this.channel,
    this.loaders = const [],
    this.gameVersions = const [],
    required this.files,
    this.pageUrl,
    this.order = 0,
  });
}

class ProjectInfo {
  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final String? pageUrl;
  const ProjectInfo({required this.id, required this.name, this.description, this.iconUrl, this.pageUrl});
}

/// One downloaded "slot" (a release folder, or a loader+game-version folder).
class DownloadRecord {
  final String slot;
  final String releaseId;
  final String version;
  final DateTime? publishedAt;

  /// Absolute paths of the files saved for this slot.
  final List<String> files;
  final DateTime downloadedAt;

  DownloadRecord({
    required this.slot,
    required this.releaseId,
    required this.version,
    required this.publishedAt,
    required this.files,
    required this.downloadedAt,
  });

  Map<String, dynamic> toJson() => {
    'slot': slot,
    'releaseId': releaseId,
    'version': version,
    'publishedAt': publishedAt?.toIso8601String(),
    'files': files,
    'downloadedAt': downloadedAt.toIso8601String(),
  };

  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
    slot: j['slot'] as String,
    releaseId: j['releaseId'] as String,
    version: j['version'] as String? ?? '',
    publishedAt: _date(j['publishedAt']),
    files: (j['files'] as List? ?? const []).cast<String>(),
    downloadedAt: _date(j['downloadedAt']) ?? DateTime.now(),
  );
}

DateTime? _date(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

class TrackedSource {
  String id;
  SourceKind kind;

  /// owner/repo for GitHub, slug or id for Modrinth / CurseForge.
  String ref;
  String name;
  bool enabled;
  TrackMode mode;

  /// Folder this source downloads into. Empty = `<global download folder>/<name>`.
  String downloadDir;

  /// Allowed channels. GitHub: beta == pre-release.
  Set<ReleaseChannel> channels;

  /// If true, a slot uses the newest *most stable* release available
  /// (release > beta > alpha) instead of simply the newest allowed one.
  bool preferStable;

  /// Regex: only files whose name matches are downloaded (empty = all).
  String includeFilesRegex;

  /// Regex: files whose name matches are skipped.
  String excludeFilesRegex;

  /// Only files with these extensions, lower-case without dot (empty = all).
  /// e.g. ["exe"], ["jar"], ["apk"], ["tar.gz"].
  List<String> fileTypes;

  /// Regex on the release version / tag (empty = all), e.g. `^v2\.`.
  String versionRegex;

  /// Website sources: only links whose full URL matches (empty = any file link).
  String linkRegex;

  /// Website sources: regex whose first group extracts the version from a
  /// link URL / text (empty = first number like 1.2.3 in the file name).
  String versionExtractRegex;

  /// Only download files suited to the current OS / CPU (GitHub, "latest" mode).
  bool onlyPlatformFiles;

  /// Also download GitHub's auto-generated source zip.
  bool includeSourceArchives;

  /// Use git tags when the repo has no releases.
  bool tagsFallback;

  /// Keep files of superseded releases / slots.
  bool keepOld;

  /// When keepOld is true: keep at most this many old entries per slot group (0 = unlimited).
  int keepCount;

  /// Lower-case loaders to include (empty = all).
  List<String> loaders;

  /// Game versions to include (empty = all).
  List<String> gameVersions;

  /// Only the newest N game versions (0 = all).
  int gameVersionLimit;
  bool includeSnapshots;

  /// Treat 1.21.1/1.21.11 as "1.21" and 26.1.1 as "26.1".
  bool groupMinorVersions;

  /// Modrinth/CurseForge: only primary files (skip sources/dev jars).
  bool primaryFileOnly;

  /// Install new downloads automatically: Android APKs (silent on Android 12+
  /// when GetterX installed the app before), desktop installers when enabled.
  bool autoInstall;

  /// Set on first check for [TrackMode.newReleases].
  DateTime? baseline;
  DateTime? lastChecked;
  String? lastError;
  String? latestVersionSeen;

  /// Folders / categories this source belongs to.
  List<String> categories;
  bool pinned;

  /// A release version the user chose to skip (the next one still shows up).
  String? skippedVersion;
  String? iconUrl;
  String? pageUrl;

  /// Android package id (auto-detected from downloaded APKs, editable).
  String? packageId;

  /// Version of the newest APK GetterX downloaded for this source.
  String? apkVersionName;
  int? apkVersionCode;

  /// Last install problem, shown under "Needs attention" until resolved.
  String? installProblem;
  List<DownloadRecord> downloads;

  TrackedSource({
    required this.id,
    required this.kind,
    required this.ref,
    required this.name,
    this.enabled = true,
    TrackMode? mode,
    this.downloadDir = '',
    Set<ReleaseChannel>? channels,
    this.preferStable = true,
    this.includeFilesRegex = '',
    this.excludeFilesRegex = '',
    List<String>? fileTypes,
    this.versionRegex = '',
    this.linkRegex = '',
    this.versionExtractRegex = '',
    this.onlyPlatformFiles = false,
    this.includeSourceArchives = false,
    this.tagsFallback = true,
    this.keepOld = false,
    this.keepCount = 0,
    List<String>? loaders,
    List<String>? gameVersions,
    this.gameVersionLimit = 0,
    this.includeSnapshots = false,
    this.groupMinorVersions = false,
    this.primaryFileOnly = true,
    this.autoInstall = false,
    this.baseline,
    this.lastChecked,
    this.lastError,
    this.latestVersionSeen,
    List<String>? categories,
    this.pinned = false,
    this.skippedVersion,
    this.iconUrl,
    this.pageUrl,
    this.packageId,
    this.apkVersionName,
    this.apkVersionCode,
    this.installProblem,
    List<DownloadRecord>? downloads,
  }) : mode =
           mode ??
           (kind == SourceKind.modrinth || kind == SourceKind.curseforge || kind == SourceKind.hangar
               ? TrackMode.latestPerLoaderAndGameVersion
               : TrackMode.latest),
       channels = channels ?? (kind == SourceKind.github ? {ReleaseChannel.release} : ReleaseChannel.values.toSet()),
       loaders = loaders ?? [],
       fileTypes = fileTypes ?? [],
       categories = categories ?? [],
       gameVersions = gameVersions ?? [],
       downloads = downloads ?? [];

  /// Minecraft-style sources with loaders / game versions.
  bool get isMod => kind == SourceKind.modrinth || kind == SourceKind.curseforge || kind == SourceKind.hangar;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'ref': ref,
    'name': name,
    'enabled': enabled,
    'mode': mode.name,
    'downloadDir': downloadDir,
    'channels': channels.map((c) => c.name).toList(),
    'preferStable': preferStable,
    'includeFilesRegex': includeFilesRegex,
    'excludeFilesRegex': excludeFilesRegex,
    'fileTypes': fileTypes,
    'versionRegex': versionRegex,
    'linkRegex': linkRegex,
    'versionExtractRegex': versionExtractRegex,
    'onlyPlatformFiles': onlyPlatformFiles,
    'includeSourceArchives': includeSourceArchives,
    'tagsFallback': tagsFallback,
    'keepOld': keepOld,
    'keepCount': keepCount,
    'loaders': loaders,
    'gameVersions': gameVersions,
    'gameVersionLimit': gameVersionLimit,
    'includeSnapshots': includeSnapshots,
    'groupMinorVersions': groupMinorVersions,
    'primaryFileOnly': primaryFileOnly,
    'autoInstall': autoInstall,
    'baseline': baseline?.toIso8601String(),
    'lastChecked': lastChecked?.toIso8601String(),
    'lastError': lastError,
    'latestVersionSeen': latestVersionSeen,
    'categories': categories,
    'pinned': pinned,
    'skippedVersion': skippedVersion,
    'iconUrl': iconUrl,
    'pageUrl': pageUrl,
    'packageId': packageId,
    'apkVersionName': apkVersionName,
    'apkVersionCode': apkVersionCode,
    'installProblem': installProblem,
    'downloads': downloads.map((d) => d.toJson()).toList(),
  };

  factory TrackedSource.fromJson(Map<String, dynamic> j) {
    final kind = SourceKind.values.byName(j['kind'] as String);
    return TrackedSource(
      id: j['id'] as String,
      kind: kind,
      ref: j['ref'] as String,
      name: j['name'] as String? ?? j['ref'] as String,
      enabled: j['enabled'] as bool? ?? true,
      mode: _enumOr(TrackMode.values, j['mode'], null),
      downloadDir: j['downloadDir'] as String? ?? '',
      channels: (j['channels'] as List?)
          ?.map((e) => _enumOr(ReleaseChannel.values, e, null))
          .whereType<ReleaseChannel>()
          .toSet(),
      preferStable: j['preferStable'] as bool? ?? true,
      includeFilesRegex: j['includeFilesRegex'] as String? ?? '',
      excludeFilesRegex: j['excludeFilesRegex'] as String? ?? '',
      fileTypes: (j['fileTypes'] as List?)?.cast<String>(),
      versionRegex: j['versionRegex'] as String? ?? '',
      linkRegex: j['linkRegex'] as String? ?? '',
      versionExtractRegex: j['versionExtractRegex'] as String? ?? '',
      onlyPlatformFiles: j['onlyPlatformFiles'] as bool? ?? false,
      includeSourceArchives: j['includeSourceArchives'] as bool? ?? false,
      tagsFallback: j['tagsFallback'] as bool? ?? true,
      keepOld: j['keepOld'] as bool? ?? false,
      keepCount: j['keepCount'] as int? ?? 0,
      loaders: (j['loaders'] as List?)?.cast<String>(),
      gameVersions: (j['gameVersions'] as List?)?.cast<String>(),
      gameVersionLimit: j['gameVersionLimit'] as int? ?? 0,
      includeSnapshots: j['includeSnapshots'] as bool? ?? false,
      groupMinorVersions: j['groupMinorVersions'] as bool? ?? false,
      primaryFileOnly: j['primaryFileOnly'] as bool? ?? true,
      autoInstall: j['autoInstall'] as bool? ?? false,
      baseline: _date(j['baseline']),
      lastChecked: _date(j['lastChecked']),
      lastError: j['lastError'] as String?,
      latestVersionSeen: j['latestVersionSeen'] as String?,
      categories: (j['categories'] as List?)?.cast<String>(),
      pinned: j['pinned'] as bool? ?? false,
      skippedVersion: j['skippedVersion'] as String?,
      iconUrl: j['iconUrl'] as String?,
      pageUrl: j['pageUrl'] as String?,
      packageId: j['packageId'] as String?,
      apkVersionName: j['apkVersionName'] as String?,
      apkVersionCode: (j['apkVersionCode'] as num?)?.toInt(),
      installProblem: j['installProblem'] as String?,
      downloads: (j['downloads'] as List? ?? const []).map((e) => DownloadRecord.fromJson((e as Map).cast())).toList(),
    );
  }

  TrackedSource copy() => TrackedSource.fromJson(toJson());
}

T? _enumOr<T extends Enum>(List<T> values, Object? name, T? fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

class AppSettings {
  /// Root folder for all downloads. Empty = platform default.
  String downloadDir;

  /// OAuth app client id for "Sign in with GitHub" (device flow).
  String githubClientId;

  /// Display names of signed-in accounts (informational).
  String githubUser;
  String itchUser;
  String modrinthUser;

  /// Secrets (tokens / API keys) are NOT stored here: see core/credentials.dart.

  /// CurseForge-compatible API base. Used without a key when the official API is unavailable.
  String curseforgeBaseUrl;

  /// Interval for automatic checks (in-app timer and OS background task).
  int checkIntervalMinutes;
  bool backgroundChecks;
  String themeMode; // system | light | dark

  /// Look for new GetterX versions (shows an "Update" button).
  bool checkAppUpdates;

  /// Download and install GetterX updates automatically.
  bool autoUpdateApp;

  /// 'system' (Material You / desktop accent) or an RGB hex such as '1bd96a'.
  String accentColor;

  /// Tint backgrounds with the accent colour (off = neutral grey backgrounds).
  bool tintedBackgrounds;

  /// Colour each source's page from its icon.
  bool perAppColors;

  /// Swipe actions in the list: none | check | pin | delete | edit | open | install.
  String swipeLeft;
  String swipeRight;

  /// Show a notification when a background check finds new versions.
  bool notifyUpdates;
  int parallelDownloads;

  AppSettings({
    this.downloadDir = '',
    this.githubClientId = '',
    this.githubUser = '',
    this.itchUser = '',
    this.modrinthUser = '',
    this.curseforgeBaseUrl = '',
    this.checkIntervalMinutes = 360,
    this.backgroundChecks = true,
    this.themeMode = 'system',
    this.checkAppUpdates = true,
    this.autoUpdateApp = false,
    this.accentColor = '1bd96a',
    this.tintedBackgrounds = false,
    this.perAppColors = true,
    this.swipeLeft = 'delete',
    this.swipeRight = 'check',
    this.notifyUpdates = true,
    this.parallelDownloads = 3,
  });

  Map<String, dynamic> toJson() => {
    'downloadDir': downloadDir,
    'githubClientId': githubClientId,
    'githubUser': githubUser,
    'itchUser': itchUser,
    'modrinthUser': modrinthUser,
    'curseforgeBaseUrl': curseforgeBaseUrl,
    'checkIntervalMinutes': checkIntervalMinutes,
    'backgroundChecks': backgroundChecks,
    'themeMode': themeMode,
    'checkAppUpdates': checkAppUpdates,
    'autoUpdateApp': autoUpdateApp,
    'accentColor': accentColor,
    'tintedBackgrounds': tintedBackgrounds,
    'perAppColors': perAppColors,
    'swipeLeft': swipeLeft,
    'swipeRight': swipeRight,
    'notifyUpdates': notifyUpdates,
    'parallelDownloads': parallelDownloads,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    downloadDir: j['downloadDir'] as String? ?? '',
    githubClientId: j['githubClientId'] as String? ?? '',
    githubUser: j['githubUser'] as String? ?? '',
    itchUser: j['itchUser'] as String? ?? '',
    modrinthUser: j['modrinthUser'] as String? ?? '',
    curseforgeBaseUrl: j['curseforgeBaseUrl'] as String? ?? '',
    checkIntervalMinutes: j['checkIntervalMinutes'] as int? ?? 360,
    backgroundChecks: j['backgroundChecks'] as bool? ?? true,
    themeMode: j['themeMode'] as String? ?? 'system',
    checkAppUpdates: j['checkAppUpdates'] as bool? ?? true,
    autoUpdateApp: j['autoUpdateApp'] as bool? ?? false,
    accentColor: j['accentColor'] as String? ?? '1bd96a',
    tintedBackgrounds: j['tintedBackgrounds'] as bool? ?? false,
    perAppColors: j['perAppColors'] as bool? ?? true,
    swipeLeft: j['swipeLeft'] as String? ?? 'delete',
    swipeRight: j['swipeRight'] as String? ?? 'check',
    notifyUpdates: j['notifyUpdates'] as bool? ?? true,
    parallelDownloads: j['parallelDownloads'] as int? ?? 3,
  );
}
