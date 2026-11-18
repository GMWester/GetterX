import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'package:getterx_core/auth.dart';
import 'package:getterx_core/credentials.dart';
import 'package:getterx_core/engine.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/paths.dart';
import 'package:getterx_core/store.dart';
import 'package:getterx_core/tls.dart';

import 'package:getterx_core/backup.dart';
import 'package:getterx_core/discovery.dart';
import 'package:getterx_core/search.dart';
import 'package:getterx_core/selector.dart';
import 'package:getterx_installer/getterx_installer.dart';

import 'desktop_installer.dart';
import 'installs.dart';
import 'notifications.dart';
import 'background.dart';
import 'secure_credentials.dart';
import 'self_update.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  final AppPaths paths;
  final ConfigStore store;
  final Engine engine;
  final CredentialStore credentialStore;
  final http.Client client;
  final Map<String, Progress> progress = {};
  Timer? _timer;
  StreamSubscription<Progress>? _sub;
  String? credentialError;
  AppUpdate? availableUpdate;
  String currentVersion = '';
  double? updateProgress;

  AppController._(this.paths, this.store, this.engine, this.credentialStore, this.client) {
    _sub = engine.progress.listen((p) {
      progress[p.sourceId] = p;
      notifyListeners();
    });
  }

  static Future<AppController> create(AppPaths paths) async {
    final store = ConfigStore(paths.dataDir);
    await store.load();
    final client = createHttpClient();
    final engine = Engine(store, client: client, defaultDownloadRoot: paths.defaultDownloadRoot);
    final c = AppController._(paths, store, engine, SecureCredentialStore(), client);
    try {
      engine.credentials = await c.credentialStore.read();
    } catch (e) {
      c.credentialError = 'Secure credential storage unavailable: $e';
    }
    c._schedule();
    WidgetsBinding.instance.addObserver(c);
    unawaited(Notifier.init());
    unawaited(c.refreshInstalled());
    unawaited(c._startupUpdateCheck());
    // Catch up on sources that are overdue (e.g. the PC was off).
    final m = c.settings.checkIntervalMinutes;
    if (m > 0 &&
        c.sources.any((s) => s.enabled && DateTime.now().difference(s.lastChecked ?? DateTime(0)).inMinutes >= m)) {
      Timer(const Duration(seconds: 5), () => c.checkAll());
    }
    return c;
  }

  AppSettings get settings => store.config.settings;
  List<TrackedSource> get sources => store.config.sources;
  Credentials get credentials => engine.credentials;
  bool get busy => engine.anyRunning;

  TrackedSource? byId(String id) => sources.where((s) => s.id == id).firstOrNull;

  void _schedule() {
    _timer?.cancel();
    final m = settings.checkIntervalMinutes;
    if (m > 0) {
      _timer = Timer.periodic(Duration(minutes: m), (_) => checkAll());
    }
  }

  Future<void> reload() async {
    await store.reload();
    notifyListeners();
  }

  Future<List<CheckResult>> checkAll() async {
    notifyListeners();
    final r = await engine.checkAll();
    await _afterResults(r);
    notifyListeners();
    return r;
  }

  Future<CheckResult> check(String id) async {
    notifyListeners();
    final r = await engine.check(id);
    _alternatives.remove(id);
    await _afterResults([r]);
    notifyListeners();
    return r;
  }

  /// Installed versions of tracked Android apps (packageId -> info).
  final installed = <String, AppPackageInfo?>{};
  final installing = <String>{};

  InstallPipeline get _pipeline => InstallPipeline(store, client, engine.credentials, background: false);

  /// Sources whose newest version changed during this app session.
  final newVersionIds = <String>{};

  Future<void> _afterResults(List<CheckResult> results) async {
    for (final r in results) {
      if (r.newVersion != null) newVersionIds.add(r.source.id);
    }
    final outcomes = await _pipeline.handle(results);
    lastInstallOutcomes = outcomes;
    await refreshInstalled();
  }

  List<InstallOutcome> lastInstallOutcomes = const [];

  /// Re-reads installed versions (Android) for the status badges.
  Future<void> refreshInstalled() async {
    if (!GetterxInstaller.supported) return;
    for (final s in sources) {
      final id = s.packageId;
      if (id == null || id.isEmpty) continue;
      try {
        installed[id] = await GetterxInstaller.installedInfo(id);
      } catch (_) {}
    }
    notifyListeners();
  }

  bool hasUpdate(TrackedSource s) => statusOf(s) == AppStatus.updateAvailable || newVersionIds.contains(s.id);

  bool needsAttention(TrackedSource s) => s.lastError != null || s.installProblem != null;

  AppStatus statusOf(TrackedSource s) => statusFor(s, s.packageId == null ? null : installed[s.packageId]);

  /// Installs the newest downloaded file of [s] now (manual "Install" / "Update").
  Future<InstallOutcome?> installLatest(TrackedSource s) async {
    final rec = s.downloads.where((d) => !isArchivedSlot(d.slot)).toList()
      ..sort((a, b) => (b.publishedAt ?? b.downloadedAt).compareTo(a.publishedAt ?? a.downloadedAt));
    for (final r in rec) {
      final f = r.files.firstWhere(
        (f) => Platform.isAndroid ? f.toLowerCase().endsWith('.apk') : isInstallable(f),
        orElse: () => '',
      );
      if (f.isEmpty || !File(f).existsSync()) continue;
      installing.add(s.id);
      notifyListeners();
      try {
        final o = await _pipeline.installFile(s, f);
        s.installProblem = o.ok || o.needsUser ? null : o.message;
        await store.saveSource(s);
        await refreshInstalled();
        return o;
      } finally {
        installing.remove(s.id);
        notifyListeners();
      }
    }
    return null;
  }

  void cancel(String id) {
    engine.cancel(id);
    notifyListeners();
  }

  Future<void> togglePin(TrackedSource s) async {
    s.pinned = !s.pinned;
    await saveSource(s);
  }

  Future<void> skipVersion(TrackedSource s, String? version) async {
    s.skippedVersion = version;
    await saveSource(s);
  }

  /// Removes a source but keeps it for a few seconds so it can be restored.
  TrackedSource? lastRemoved;
  Future<void> removeWithUndo(TrackedSource s) async {
    lastRemoved = s.copy();
    await store.removeSource(s.id);
    notifyListeners();
  }

  Future<void> undoRemove() async {
    final s = lastRemoved;
    if (s == null) return;
    lastRemoved = null;
    await saveSource(s);
  }

  List<String> get allCategories => {for (final s in sources) ...s.categories}.toList()..sort();

  /// Moves [s] to another source (e.g. CurseForge -> Modrinth) keeping its settings and folder.
  Future<TrackedSource> switchSource(TrackedSource s, String link) async {
    final fresh = await resolveLink(link);
    s
      ..kind = fresh.kind
      ..ref = fresh.ref
      ..iconUrl = fresh.iconUrl ?? s.iconUrl
      ..pageUrl = fresh.pageUrl
      ..baseline = null
      ..latestVersionSeen = null;
    if (s.downloadDir.isEmpty) s.downloadDir = engine.folderFor(s); // keep files where they are
    await saveSource(s);
    return s;
  }

  /// Adds another listing of the same project, copying the settings of [s].
  Future<TrackedSource> trackAlternative(TrackedSource s, String link) async {
    final fresh = await resolveLink(link);
    final copy = TrackedSource.fromJson({
      ...s.toJson(),
      'id': fresh.id,
      'kind': fresh.kind.name,
      'ref': fresh.ref,
      'name': '${s.name} (${sourceKindLabel(fresh.kind)})',
      'iconUrl': fresh.iconUrl ?? s.iconUrl,
      'pageUrl': fresh.pageUrl,
      'downloadDir': '',
      'downloads': <Object>[],
      'baseline': null,
      'latestVersionSeen': null,
      'lastChecked': null,
      'lastError': null,
    });
    await saveSource(copy);
    return copy;
  }

  Searcher get searcher =>
      Searcher(client, credentials: engine.credentials, curseforgeBaseUrl: settings.curseforgeBaseUrl);

  final _alternatives = <String, Future<List<Alternative>>>{};
  Future<List<Alternative>> alternatives(TrackedSource s) => _alternatives.putIfAbsent(s.id, () async {
    List<RemoteRelease> rels = const [];
    if (s.kind == SourceKind.curseforge) {
      try {
        rels = await engine.fetchReleases(s);
      } catch (_) {}
    }
    return Discovery(
      client,
      credentials: engine.credentials,
      curseforgeBaseUrl: settings.curseforgeBaseUrl,
    ).find(s, releases: rels);
  });

  String exportConfig({bool includeHistory = false}) => exportBackup(settings, sources, includeHistory: includeHistory);

  /// Adds the selected sources from a backup (skipping ones already tracked).
  Future<int> importSources(List<TrackedSource> picked) async {
    var n = 0;
    for (final s in picked) {
      if (sources.any((e) => e.kind == s.kind && e.ref.toLowerCase() == s.ref.toLowerCase())) continue;
      await store.saveSource(s);
      n++;
    }
    notifyListeners();
    return n;
  }

  Future<TrackedSource> resolveLink(String link, {SourceKind? kind}) => engine.createFromLink(link, forceKind: kind);

  Future<void> saveSource(TrackedSource s) async {
    await store.saveSource(s);
    notifyListeners();
  }

  Future<void> removeSource(TrackedSource s, {required bool deleteFiles}) async {
    if (deleteFiles) await engine.deleteAllFiles(s);
    await store.removeSource(s.id);
    notifyListeners();
  }

  Future<String?> saveSettings() async {
    await store.saveSettings();
    _schedule();
    final err = await configureBackground(
      enabled: settings.backgroundChecks,
      intervalMinutes: settings.checkIntervalMinutes,
    );
    notifyListeners();
    return err;
  }

  // ---------------- credentials ----------------

  Future<void> setCredentials(Credentials c) async {
    await credentialStore.write(c);
    engine.credentials = c;
    notifyListeners();
  }

  Auth get auth => Auth(client);

  // ---------------- self update ----------------

  SelfUpdater get updater => SelfUpdater(client);

  Future<void> _startupUpdateCheck() async {
    try {
      currentVersion = await updater.currentVersion();
      notifyListeners();
      if (!settings.checkAppUpdates && !settings.autoUpdateApp) return;
      await checkForAppUpdate();
      if (availableUpdate != null && settings.autoUpdateApp && availableUpdate!.asset != null) {
        await installAppUpdate();
      }
    } catch (_) {
      // Offline or rate-limited: try again next start.
    }
  }

  Future<AppUpdate?> checkForAppUpdate() async {
    availableUpdate = await updater.check();
    notifyListeners();
    return availableUpdate;
  }

  Future<void> installAppUpdate() async {
    final u = availableUpdate;
    if (u == null) return;
    updateProgress = 0;
    notifyListeners();
    try {
      await updater.install(
        u,
        onProgress: (f) {
          updateProgress = f;
          notifyListeners();
        },
      );
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  List<LogEntry> log() => store.readLog();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Apps may have been installed/updated/removed while GetterX was away.
    if (state == AppLifecycleState.resumed) unawaited(refreshInstalled());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _sub?.cancel();
    engine.dispose();
    super.dispose();
  }
}
