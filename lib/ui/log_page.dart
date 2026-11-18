import 'package:material_ui/material_ui.dart';

import '../app/controller.dart';
import 'common.dart';

class LogPage extends StatelessWidget {
  final AppController c;
  const LogPage(this.c, {super.key});
  @override
  Widget build(BuildContext context) {
    final entries = c.log();
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: entries.isEmpty
          ? const Center(child: Text('No activity yet'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  dense: true,
                  leading: Icon(switch (e.level) {
                    'download' => Icons.download_done,
                    'delete' => Icons.delete_outline,
                    'error' => Icons.error_outline,
                    _ => Icons.info_outline,
                  }, color: e.level == 'error' ? Theme.of(context).colorScheme.error : null),
                  title: Text(e.message),
                  subtitle: Text(ago(e.time)),
                );
              },
            ),
    );
  }
}
