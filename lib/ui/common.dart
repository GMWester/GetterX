import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:getterx_core/models.dart';

IconData kindIcon(SourceKind k) => switch (k) {
  SourceKind.github => Icons.code,
  SourceKind.modrinth => Icons.extension,
  SourceKind.curseforge => Icons.local_fire_department,
  SourceKind.itchio => Icons.videogame_asset,
  SourceKind.gitlab => Icons.merge_type,
  SourceKind.forgejo => Icons.account_tree_outlined,
  SourceKind.fdroid => Icons.android,
  SourceKind.web => Icons.language,
};

String ago(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 60) return '${d.inDays} d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Folder picker. On Android, folders outside the app's own area need
/// "All files access".
Future<String?> pickFolder(BuildContext context, {String? initial}) async {
  // ignore: deprecated_member_use
  final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose download folder', initialDirectory: initial);
  if (dir == null) return null;
  if (Platform.isAndroid && !await Permission.manageExternalStorage.isGranted) {
    final ok = await Permission.manageExternalStorage.request();
    if (!ok.isGranted && context.mounted) {
      toast(context, 'GetterX may not be able to write there without "All files access".');
    }
  }
  return dir;
}

Future<void> openFolder(String path) async {
  await Directory(path).create(recursive: true);
  if (Platform.isWindows) {
    await Process.start('explorer', [path]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path]);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [path]);
  } else {
    await OpenFilex.open(path);
  }
}

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    ) ??
    false;

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// First few lines of a long error text, for tooltips and list rows.
String shortError(String text, {int lines = 4}) {
  final all = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (all.length <= lines) return all.join('\n');
  return '${all.take(lines).join('\n')}\n… and ${all.length - lines} more (open the source for details)';
}
