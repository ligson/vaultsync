import 'package:flutter/material.dart';

enum VaultThemePreset {
  celadon,
  cinnabar,
  inkBamboo,
  indigo,
  pineSmoke,
  nightCinnabar,
  blackGold,
  deepIndigo,
}

extension VaultThemePresetDetails on VaultThemePreset {
  String get id => switch (this) {
    VaultThemePreset.celadon => 'celadon',
    VaultThemePreset.cinnabar => 'cinnabar',
    VaultThemePreset.inkBamboo => 'ink_bamboo',
    VaultThemePreset.indigo => 'indigo',
    VaultThemePreset.pineSmoke => 'pine_smoke',
    VaultThemePreset.nightCinnabar => 'night_cinnabar',
    VaultThemePreset.blackGold => 'black_gold',
    VaultThemePreset.deepIndigo => 'deep_indigo',
  };

  String get label => switch (this) {
    VaultThemePreset.celadon => '青瓷',
    VaultThemePreset.cinnabar => '朱砂',
    VaultThemePreset.inkBamboo => '墨竹',
    VaultThemePreset.indigo => '黛蓝',
    VaultThemePreset.pineSmoke => '松烟',
    VaultThemePreset.nightCinnabar => '夜朱',
    VaultThemePreset.blackGold => '乌金',
    VaultThemePreset.deepIndigo => '深黛',
  };

  String get description => switch (this) {
    VaultThemePreset.celadon => '温润青绿，配以暖陶点色',
    VaultThemePreset.cinnabar => '沉静朱红，辅以松柏青',
    VaultThemePreset.inkBamboo => '墨色竹青，清简克制',
    VaultThemePreset.indigo => '传统黛蓝，配以古铜色',
    VaultThemePreset.pineSmoke => '松柏青绿，配以烟灰黑',
    VaultThemePreset.nightCinnabar => '夜色朱砂，配以暖灰白',
    VaultThemePreset.blackGold => '墨黑底色，配以古铜金',
    VaultThemePreset.deepIndigo => '深沉黛蓝，配以月白色',
  };

  Color get primary => switch (this) {
    VaultThemePreset.celadon => const Color(0xFF3F6D64),
    VaultThemePreset.cinnabar => const Color(0xFF9B3532),
    VaultThemePreset.inkBamboo => const Color(0xFF355B48),
    VaultThemePreset.indigo => const Color(0xFF385573),
    VaultThemePreset.pineSmoke => const Color(0xFF8DB5A0),
    VaultThemePreset.nightCinnabar => const Color(0xFFE08B82),
    VaultThemePreset.blackGold => const Color(0xFFD4A95D),
    VaultThemePreset.deepIndigo => const Color(0xFF9DB9D8),
  };

  Color get accent => switch (this) {
    VaultThemePreset.celadon => const Color(0xFFA65F3E),
    VaultThemePreset.cinnabar => const Color(0xFF4F6A59),
    VaultThemePreset.inkBamboo => const Color(0xFF746252),
    VaultThemePreset.indigo => const Color(0xFF93603E),
    VaultThemePreset.pineSmoke => const Color(0xFFC3A77A),
    VaultThemePreset.nightCinnabar => const Color(0xFF9DB99D),
    VaultThemePreset.blackGold => const Color(0xFFB97843),
    VaultThemePreset.deepIndigo => const Color(0xFFD0B17F),
  };

  Color get surface => switch (this) {
    VaultThemePreset.celadon => const Color(0xFFF5F8F5),
    VaultThemePreset.cinnabar => const Color(0xFFFAF7F3),
    VaultThemePreset.inkBamboo => const Color(0xFFF4F6F2),
    VaultThemePreset.indigo => const Color(0xFFF5F7F9),
    VaultThemePreset.pineSmoke => const Color(0xFF18231F),
    VaultThemePreset.nightCinnabar => const Color(0xFF271C1D),
    VaultThemePreset.blackGold => const Color(0xFF1D1B18),
    VaultThemePreset.deepIndigo => const Color(0xFF18202B),
  };

  Brightness get brightness => switch (this) {
    VaultThemePreset.celadon ||
    VaultThemePreset.cinnabar ||
    VaultThemePreset.inkBamboo ||
    VaultThemePreset.indigo => Brightness.light,
    VaultThemePreset.pineSmoke ||
    VaultThemePreset.nightCinnabar ||
    VaultThemePreset.blackGold ||
    VaultThemePreset.deepIndigo => Brightness.dark,
  };

  static VaultThemePreset fromId(String? id) {
    return VaultThemePreset.values.firstWhere(
      (preset) => preset.id == id,
      orElse: () => VaultThemePreset.celadon,
    );
  }
}

ThemeData buildVaultTheme(VaultThemePreset preset) {
  final generated = ColorScheme.fromSeed(
    seedColor: preset.primary,
    brightness: preset.brightness,
  );
  final colorScheme = generated.copyWith(
    primary: preset.primary,
    secondary: preset.accent,
    tertiary: preset.accent,
    surface: preset.surface,
    surfaceTint: preset.primary,
  );
  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: preset.surface,
    useMaterial3: true,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: preset.surface,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Color.alphaBlend(
        preset.primary.withValues(alpha: 0.05),
        preset.surface,
      ),
      indicatorColor: colorScheme.primaryContainer,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      backgroundColor: colorScheme.inverseSurface,
      contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: preset.primary,
      linearTrackColor: colorScheme.surfaceContainerHighest,
    ),
    dividerTheme: DividerThemeData(color: colorScheme.outlineVariant),
  );
}
