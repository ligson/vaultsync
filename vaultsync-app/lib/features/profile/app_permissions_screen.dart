import 'package:flutter/material.dart';

import 'app_permission_gateway.dart';

class AppPermissionsScreen extends StatefulWidget {
  final AppPermissionGateway gateway;
  final String platform;

  const AppPermissionsScreen({
    super.key,
    required this.gateway,
    required this.platform,
  });

  @override
  State<AppPermissionsScreen> createState() => _AppPermissionsScreenState();
}

class _AppPermissionsScreenState extends State<AppPermissionsScreen>
    with WidgetsBindingObserver {
  AppPermissionSnapshot? _snapshot;
  Object? _error;
  bool _checking = false;

  bool get _isAndroid => widget.platform == 'android';

  bool get _isMacOS => widget.platform == 'macos';

  bool get _supportsMedia =>
      widget.platform == 'android' ||
      widget.platform == 'ios' ||
      widget.platform == 'macos';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    if (_checking) {
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final snapshot = await widget.gateway.checkPermissions();
      if (mounted) {
        setState(() => _snapshot = snapshot);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _request(Future<void> Function() request) async {
    await request();
    await _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('权限与存储'),
        actions: [
          IconButton(
            key: const ValueKey('refresh_permissions_button'),
            tooltip: '重新检查',
            onPressed: _checking ? null : _checkPermissions,
            icon: _checking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        key: const ValueKey('app_permissions_list'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _PermissionSummary(snapshot: snapshot, error: _error),
          const SizedBox(height: 20),
          Text('同步权限', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _PermissionTile(
            key: const ValueKey('media_permission_tile'),
            icon: Icons.photo_library_outlined,
            title: '照片和视频',
            description: _supportsMedia
                ? _isMacOS
                      ? '用于访问 macOS 照片图库并备份照片、视频。'
                      : '用于扫描相册并备份照片、视频。'
                : '当前平台通过文件夹选择器管理照片和视频目录，无需单独授权。',
            state: snapshot?.media,
            onRequest: snapshot?.media == AppPermissionState.notRequired
                ? null
                : () => _request(widget.gateway.requestMediaPermission),
          ),
          const Divider(height: 1, indent: 52),
          _PermissionTile(
            key: const ValueKey('file_access_permission_tile'),
            icon: Icons.folder_outlined,
            title: '共享文件夹访问',
            description: _isAndroid
                ? '用于扫描下载目录等共享存储中的完整文件夹。'
                : _isMacOS
                ? '文件夹访问由系统目录选择器管理，选择同步目录时授予权限。'
                : '当前平台通过系统目录选择器管理文件夹访问。',
            state: snapshot?.allFiles,
            onRequest: snapshot?.allFiles == AppPermissionState.notRequired
                ? null
                : () => _request(widget.gateway.requestFileAccessPermission),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            key: const ValueKey('open_system_settings_button'),
            onPressed: widget.gateway.openSystemSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('打开系统设置'),
          ),
          const SizedBox(height: 10),
          Text(
            '修改权限后返回 VaultSync，页面会自动重新检查。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionSummary extends StatelessWidget {
  final AppPermissionSnapshot? snapshot;
  final Object? error;

  const _PermissionSummary({required this.snapshot, required this.error});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isReady = snapshot?.isFullyGranted == true;
    final title = error != null
        ? '权限状态检查失败'
        : snapshot == null
        ? '正在检查权限'
        : isReady
        ? '同步权限已满足'
        : '有权限需要处理';
    final message = error != null
        ? '暂时无法读取系统权限，请重新检查。'
        : snapshot == null
        ? '正在读取当前设备的授权状态。'
        : isReady
        ? '相册备份和共享文件夹同步可以正常工作。'
        : '请处理下方未授权项目，否则对应目录可能无法扫描或上传。';
    final color = error != null
        ? colorScheme.error
        : isReady
        ? colorScheme.primary
        : colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isReady ? Icons.verified_outlined : Icons.shield_outlined,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(message),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final AppPermissionState? state;
  final VoidCallback? onRequest;

  const _PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.state,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AppPermissionState.granted => (
        '已授权',
        Theme.of(context).colorScheme.primary,
      ),
      AppPermissionState.limited => (
        '部分授权',
        Theme.of(context).colorScheme.tertiary,
      ),
      AppPermissionState.denied => ('未授权', Theme.of(context).colorScheme.error),
      AppPermissionState.notRequired => (
        '无需额外授权',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      null => ('检查中', Theme.of(context).colorScheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: onRequest,
            child: Text(
              state == AppPermissionState.granted ? '已授权' : label,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
