import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';

import 'package:getterx_core/auth.dart';
import 'package:getterx_core/credentials.dart';
import 'package:getterx_core/engine.dart';
import 'package:getterx_core/models.dart';
import 'package:getterx_core/paths.dart';
import 'package:getterx_core/store.dart';
import 'background.dart';
import 'secure_credentials.dart';
import 'self_update.dart';

class AppController extends ChangeNotifier {
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
    final client = http.Client();
    final engine = Engine(store, client: client, defaultDownloadRoot: paths.defaultDownloadRoot);
    final c = AppController._(paths, store, engine, SecureCredentialStore(), client);
    try {
      engine.credentials = await c.credentialStore.read();
    } catch (e) {
      c.credentialError = 'Secure credential storage unavailable: $e';
    }
    c._schedule();
    unawaited(c._startupUpdateCheck());
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
    await _afterResults([r]);
    notifyListeners();
    return r;
  }

  Future<void> _afterResults(List<CheckResult> results) async {
    if (!Platform.isAndroid) return;
    for (final r in results) {
      if (!r.source.autoInstall || r.source.mode != TrackMode.latest) continue;
      for (final f in r.downloaded.expand((d) => d.files)) {
        if (f.toLowerCase().endsWith('.apk')) {
          await OpenFilex.open(f, type: 'application/vnd.android.package-archive');
        }
      }
    }
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
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    engine.dispose();
    super.dispose();
  }
}
