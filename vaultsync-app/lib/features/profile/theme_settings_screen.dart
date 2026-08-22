import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class ThemeSettingsScreen extends StatefulWidget {
  final VaultThemePreset selectedTheme;
  final Future<void> Function(VaultThemePreset theme) onThemeChanged;

  const ThemeSettingsScreen({
    super.key,
    required this.selectedTheme,
    required this.onThemeChanged,
  });

  @override
  State<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemeSettingsScreenState extends State<ThemeSettingsScreen> {
  late VaultThemePreset _selectedTheme;
  VaultThemePreset? _savingTheme;

  @override
  void initState() {
    super.initState();
    _selectedTheme = widget.selectedTheme;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('主题外观')),
      body: ListView.separated(
        key: const ValueKey('theme_settings_list'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: VaultThemePreset.values.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
        itemBuilder: (context, index) {
          final preset = VaultThemePreset.values[index];
          final selected = preset == _selectedTheme;
          final saving = preset == _savingTheme;
          return ListTile(
            key: ValueKey('theme_option_${preset.id}'),
            minTileHeight: 72,
            leading: _ThemeSwatch(preset: preset),
            title: Text(preset.label),
            subtitle: Text(preset.description),
            trailing: SizedBox.square(
              dimension: 24,
              child: saving
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : selected
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
            selected: selected,
            onTap: _savingTheme == null || selected
                ? () => _selectTheme(preset)
                : null,
          );
        },
      ),
    );
  }

  Future<void> _selectTheme(VaultThemePreset preset) async {
    if (preset == _selectedTheme || _savingTheme != null) {
      return;
    }
    setState(() {
      _selectedTheme = preset;
      _savingTheme = preset;
    });
    try {
      await widget.onThemeChanged(preset);
    } finally {
      if (mounted) {
        setState(() => _savingTheme = null);
      }
    }
  }
}

class _ThemeSwatch extends StatelessWidget {
  final VaultThemePreset preset;

  const _ThemeSwatch({required this.preset});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${preset.label}配色',
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          children: [
            Positioned(
              left: 2,
              top: 2,
              child: _ColorDot(color: preset.primary, size: 30),
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: _ColorDot(color: preset.accent, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final double size;

  const _ColorDot({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: 2,
        ),
      ),
    );
  }
}
