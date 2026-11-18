import 'package:getterx_core/models.dart';
import 'package:getterx_core/sources/source.dart';
import 'package:getterx_installer/getterx_installer.dart';
import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import 'common.dart';

/// Finds F-Droid / IzzyOnDroid sources for the apps installed on this device.
class DeviceImportPage extends StatefulWidget {
  final AppController c;
  const DeviceImportPage(this.c, {super.key});
  @override
  State<DeviceImportPage> createState() => _DeviceImportPageState();
}

class _Match {
  final AppPackageInfo app;
  final SourceKind kind;
  bool selected = true;
  _Match(this.app, this.kind);
}

class _DeviceImportPageState extends State<DeviceImportPage> {
  List<AppPackageInfo>? _apps;
  final _matches = <_Match>[];
  int _done = 0;
  bool _searching = false;
  bool _autoInstall = true;

  @override
  void initState() {
    super.initState();
    GetterxInstaller.installedApps().then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  Future<void> _find() async {
    final apps = _apps ?? const [];
    final tracked = widget.c.sources.map((s) => s.packageId).whereType<String>().toSet();
    setState(() {
      _searching = true;
      _matches.clear();
      _done = 0;
    });
    final client = widget.c.client;
    for (final app in apps) {
      if (!mounted) return;
      if (!tracked.contains(app.packageName)) {
        for (final (kind, host, base) in [
          (SourceKind.fdroid, 'f-droid.org', ''),
          (SourceKind.izzyondroid, 'apt.izzysoft.de', '/fdroid'),
        ]) {
          try {
            await getJson(client, Uri.https(host, '$base/api/v1/packages/${app.packageName}'));
            _matches.add(_Match(app, kind));
            break; // prefer F-Droid when on both
          } catch (_) {}
        }
      }
      setState(() => _done++);
    }
    setState(() => _searching = false);
  }

  Future<void> _add() async {
    var n = 0;
    for (final m in _matches.where((m) => m.selected)) {
      final s = TrackedSource(
        id: '${m.kind.name}:${m.app.packageName}:${DateTime.now().microsecondsSinceEpoch}',
        kind: m.kind,
        ref: m.app.packageName,
        name: m.app.label ?? m.app.packageName,
        packageId: m.app.packageName,
        onlyPlatformFiles: true,
        autoInstall: _autoInstall,
      );
      await widget.c.saveSource(s);
      n++;
    }
    if (mounted) {
      toast(context, 'Added $n app${n == 1 ? '' : 's'}');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    return Scaffold(
      appBar: AppBar(title: const Text('Import from device')),
      body: apps == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  title: Text('${apps.length} apps installed'),
                  subtitle: const Text('Looks each one up on F-Droid and IzzyOnDroid by its package id.'),
                  trailing: FilledButton(onPressed: _searching ? null : _find, child: const Text('Find sources')),
                ),
                if (_searching) LinearProgressIndicator(value: apps.isEmpty ? null : _done / apps.length),
                if (_matches.isNotEmpty) ...[
                  SwitchListTile(
                    value: _autoInstall,
                    onChanged: (v) => setState(() => _autoInstall = v),
                    title: const Text('Install their updates automatically'),
                    subtitle: const Text(
                      'Note: an app installed from another store has a different signature and must be reinstalled once from here.',
                    ),
                  ),
                  for (final m in _matches)
                    CheckboxListTile(
                      value: m.selected,
                      onChanged: (v) => setState(() => m.selected = v!),
                      title: Text(m.app.label ?? m.app.packageName),
                      subtitle: Text(
                        '${m.app.packageName} · ${sourceKindLabel(m.kind)} · installed ${m.app.versionName ?? '?'}',
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: _add,
                      child: Text('Track ${_matches.where((m) => m.selected).length} selected'),
                    ),
                  ),
                ] else if (!_searching && _done > 0)
                  const ListTile(title: Text('None of your apps were found on F-Droid or IzzyOnDroid.')),
              ],
            ),
    );
  }
}
