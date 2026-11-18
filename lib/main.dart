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
        final mode = c.settings.themeMode;
        final dark = ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark);
        return MaterialApp(
          title: 'GetterX',
          debugShowCheckedModeBanner: false,
          themeMode: switch (mode) {
            'light' => ThemeMode.light,
            'dark' || 'oled' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
          darkTheme: mode == 'oled' ? oledTheme(dark) : dark,
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

/// Pure-black theme for OLED screens (pixels off = less power, no glow).
ThemeData oledTheme(ThemeData dark) {
  final cs = dark.colorScheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceBright: const Color(0xFF121212),
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF050505),
    surfaceContainer: const Color(0xFF0A0A0A),
    surfaceContainerHigh: const Color(0xFF101010),
    surfaceContainerHighest: const Color(0xFF161616),
  );
  return dark.copyWith(
    colorScheme: cs,
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    appBarTheme: dark.appBarTheme.copyWith(backgroundColor: Colors.black, surfaceTintColor: Colors.transparent),
    cardTheme: dark.cardTheme.copyWith(color: const Color(0xFF0A0A0A), surfaceTintColor: Colors.transparent),
    dialogTheme: dark.dialogTheme.copyWith(backgroundColor: const Color(0xFF0A0A0A)),
    dividerColor: const Color(0xFF1E1E1E),
  );
}
