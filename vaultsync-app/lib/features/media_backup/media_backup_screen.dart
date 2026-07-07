import 'package:flutter/material.dart';

class MediaBackupDraft {
  final String mediaTypes;
  final String cleanupPolicy;
  final bool wifiOnly;
  final bool autoBackupEnabled;

  const MediaBackupDraft({
    required this.mediaTypes,
    required this.cleanupPolicy,
    required this.wifiOnly,
    required this.autoBackupEnabled,
  });
}

class MediaBackupScreen extends StatefulWidget {
  final Future<void> Function(MediaBackupDraft draft) onSave;

  const MediaBackupScreen({super.key, required this.onSave});

  @override
  State<MediaBackupScreen> createState() => _MediaBackupScreenState();
}

class _MediaBackupScreenState extends State<MediaBackupScreen> {
  String _mediaTypes = 'image_video';
  String _cleanupPolicy = 'keep';
  bool _deletePolicyConfirmed = false;
  bool _wifiOnly = true;
  bool _autoBackupEnabled = true;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('相册备份')),
      body: ListView(
        children: [
          const _SectionTitle('备份内容'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'image_video', label: Text('照片和视频')),
                ButtonSegment(value: 'image', label: Text('仅照片')),
                ButtonSegment(value: 'video', label: Text('仅视频')),
              ],
              selected: {_mediaTypes},
              onSelectionChanged: (value) {
                setState(() => _mediaTypes = value.single);
              },
            ),
          ),
          const Divider(),
          const _SectionTitle('本地处理'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'keep', label: Text('保留本地照片和视频')),
                ButtonSegment(value: 'delete', label: Text('上传后删除本地照片和视频')),
              ],
              selected: {_cleanupPolicy},
              onSelectionChanged: (value) {
                final selected = value.single;
                if (selected == 'delete') {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _confirmDeletePolicy();
                  });
                  return;
                }
                setState(() {
                  _cleanupPolicy = selected;
                  _deletePolicyConfirmed = false;
                });
              },
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('仅 Wi-Fi 上传'),
            value: _wifiOnly,
            onChanged: (value) => setState(() => _wifiOnly = value),
          ),
          SwitchListTile(
            title: const Text('自动备份'),
            value: _autoBackupEnabled,
            onChanged: (value) => setState(() => _autoBackupEnabled = value),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton(
          key: const ValueKey('save_media_backup_button'),
          onPressed: _isSaving ? null : _save,
          child: Text(_isSaving ? '保存中...' : '保存'),
        ),
      ),
    );
  }

  Future<void> _confirmDeletePolicy() async {
    final confirmed = await _showDeletePolicyDialog();
    if (!mounted) {
      return;
    }
    if (confirmed) {
      setState(() {
        _cleanupPolicy = 'delete';
        _deletePolicyConfirmed = true;
      });
    }
  }

  Future<bool> _showDeletePolicyDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除本地相册资源'),
        content: const Text(
          '文件会先加密上传到服务器。服务器确认保存后，VaultSync 才会请求系统删除本地照片和视频。本地删除不等于删除服务器备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我已了解，继续'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _save() async {
    if (_cleanupPolicy == 'delete' && !_deletePolicyConfirmed) {
      final confirmed = await _showDeletePolicyDialog();
      if (!mounted || !confirmed) {
        return;
      }
      setState(() => _deletePolicyConfirmed = true);
    }
    setState(() => _isSaving = true);
    await widget.onSave(
      MediaBackupDraft(
        mediaTypes: _mediaTypes,
        cleanupPolicy: _cleanupPolicy,
        wifiOnly: _wifiOnly,
        autoBackupEnabled: _autoBackupEnabled,
      ),
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
