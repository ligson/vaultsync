import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/theme/app_theme.dart';

void main() {
  test('provides four light and four dark Chinese themes', () {
    expect(VaultThemePreset.values, hasLength(8));
    expect(
      VaultThemePreset.values.where(
        (preset) => preset.brightness == Brightness.light,
      ),
      hasLength(4),
    );
    expect(
      VaultThemePreset.values.where(
        (preset) => preset.brightness == Brightness.dark,
      ),
      hasLength(4),
    );
  });

  test('dark themes use dark Material color schemes', () {
    for (final preset in [
      VaultThemePreset.pineSmoke,
      VaultThemePreset.nightCinnabar,
      VaultThemePreset.blackGold,
      VaultThemePreset.deepIndigo,
    ]) {
      final theme = buildVaultTheme(preset);
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, preset.surface);
      expect(theme.colorScheme.onSurface, isNot(preset.surface));
    }
  });

  test('theme IDs round-trip and unknown IDs use the celadon default', () {
    for (final preset in VaultThemePreset.values) {
      expect(VaultThemePresetDetails.fromId(preset.id), preset);
    }
    expect(
      VaultThemePresetDetails.fromId('future_theme'),
      VaultThemePreset.celadon,
    );
  });
}
