import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:getterx_core/paths.dart';

Future<AppPaths> resolveAppPaths() async {
  if (Platform.isAndroid) {
    final data = await getApplicationSupportDirectory();
    // Public Download/GetterX so files are visible in file managers.
    var root = '/storage/emulated/0/Download/GetterX';
    try {
      await Directory(root).create(recursive: true);
      final probe = File(p.join(root, '.getterx-write-test'));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      final ext = await getExternalStorageDirectory();
      root = p.join((ext ?? data).path, 'Downloads');
    }
    return AppPaths(data, root, false, data.path);
  }
  if (Platform.isIOS) {
    final data = await getApplicationSupportDirectory();
    // Documents is visible in the Files app (UIFileSharingEnabled).
    final docs = await getApplicationDocumentsDirectory();
    return AppPaths(data, p.join(docs.path, 'GetterX'), false, data.path);
  }
  return resolveDesktopPaths();
}
