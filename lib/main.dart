import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app_paths.dart';
import 'app/background.dart';
import 'app/controller.dart';
import 'ui/home_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop scheduled task: check and exit without ever showing a window.
  if (args.contains('--background-check')) {
    final ok = await runBackgroundCheck();
    exit(ok ? 0 : 1);
  }

  await initBackground();
  final paths = await resolveAppPaths();
  final controller = await AppController.create(paths);
  if (controller.settings.backgroundChecks && (Platform.isAndroid || Platform.isIOS)) {
    await configureBackground(enabled: true, intervalMinutes: controller.settings.checkIntervalMinutes);
  }
  runApp(GetterXApp(controller));
}

class GetterXApp extends StatelessWidget {
  final AppController c;
  const GetterXApp(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        const seed = Color(0xFF1BD96A);
        return MaterialApp(
          title: 'GetterX',
          debugShowCheckedModeBanner: false,
          themeMode: switch (c.settings.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
          darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
          // Android TV remotes: the centre/select button activates the focused item.
          shortcuts: {
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          home: HomePage(c),
        );
      },
    );
  }
}
