import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app_paths.dart';
import 'app/background.dart';
import 'app/controller.dart';
import 'app/theme.dart';
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
  if (!(Platform.isAndroid || Platform.isIOS) && !controller.settings.desktopBackgroundChecks) {
    // Clean up the scheduled task older versions created without asking.
    unawaited(removeUnwantedDesktopTask());
  }
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
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final st = c.settings;
          final mode = st.themeMode;
          final useSystem = st.accentColor == 'system';
          final lightSeed = useSystem && lightDynamic != null ? lightDynamic.primary : parseAccent(st.accentColor);
          final darkSeed = useSystem && darkDynamic != null ? darkDynamic.primary : parseAccent(st.accentColor);
          final light = buildTheme(buildScheme(lightSeed, Brightness.light, tinted: st.tintedBackgrounds));
          final dark = buildTheme(buildScheme(darkSeed, Brightness.dark, tinted: st.tintedBackgrounds));
          return MaterialApp(
            title: 'GetterX',
            debugShowCheckedModeBanner: false,
            themeMode: switch (mode) {
              'light' => ThemeMode.light,
              'dark' || 'oled' => ThemeMode.dark,
              _ => ThemeMode.system,
            },
            theme: light,
            darkTheme: mode == 'oled' ? oledTheme(dark) : dark,
            // Android TV remotes: the centre/select button activates the focused item.
            shortcuts: {
              ...WidgetsApp.defaultShortcuts,
              const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
            },
            home: HomePage(c),
          );
        },
      ),
    );
  }
}
