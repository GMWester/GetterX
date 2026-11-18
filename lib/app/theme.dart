import 'package:material_ui/material_ui.dart';

/// Accent presets (RGB hex) shown in Settings, plus 'system'.
const accentPresets = <String, String>{
  '1bd96a': 'Green',
  '4c8dff': 'Blue',
  '8b6cff': 'Purple',
  'ff6b9a': 'Pink',
  'ff5252': 'Red',
  'ff9800': 'Orange',
  'ffd54f': 'Yellow',
  '26c6da': 'Teal',
  '9e9e9e': 'Grey',
};

Color parseAccent(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? const Color(0xFF1BD96A) : Color(0xFF000000 | v);
}

/// Accent colour for buttons/highlights; backgrounds stay neutral grey unless
/// [tinted] is on (the default Material scheme tints every surface with the
/// accent, which made dark mode look green).
ColorScheme buildScheme(Color seed, Brightness b, {required bool tinted}) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
  if (tinted) return scheme;
  final n = ColorScheme.fromSeed(seedColor: seed, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.monochrome);
  return scheme.copyWith(
    surface: n.surface,
    surfaceDim: n.surfaceDim,
    surfaceBright: n.surfaceBright,
    surfaceContainerLowest: n.surfaceContainerLowest,
    surfaceContainerLow: n.surfaceContainerLow,
    surfaceContainer: n.surfaceContainer,
    surfaceContainerHigh: n.surfaceContainerHigh,
    surfaceContainerHighest: n.surfaceContainerHighest,
    onSurface: n.onSurface,
    onSurfaceVariant: n.onSurfaceVariant,
    outline: n.outline,
    outlineVariant: n.outlineVariant,
    inverseSurface: n.inverseSurface,
    onInverseSurface: n.onInverseSurface,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildTheme(ColorScheme scheme) => ThemeData(colorScheme: scheme);

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
    surfaceTint: Colors.transparent,
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

/// A theme coloured from an app/mod icon (per-app colours on detail pages).
Future<ThemeData?> themeFromIcon(String url, ThemeData base, {required bool tinted}) async {
  try {
    final s = await ColorScheme.fromImageProvider(provider: NetworkImage(url), brightness: base.colorScheme.brightness);
    final scheme = buildScheme(s.primary, base.colorScheme.brightness, tinted: tinted);
    final isOled = base.scaffoldBackgroundColor == Colors.black;
    final t = buildTheme(scheme);
    return isOled ? oledTheme(t) : t;
  } catch (_) {
    return null;
  }
}
