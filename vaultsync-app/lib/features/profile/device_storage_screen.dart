import 'package:flutter/material.dart';

import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';

class DeviceStorageScreen extends StatefulWidget {
  final SessionStore storage;
  final StorageUsageGateway gateway;

  const DeviceStorageScreen({
    super.key,
    required this.storage,
    required this.gateway,
  });

  @override
  State<DeviceStorageScreen> createState() => _DeviceStorageScreenState();
}

class _DeviceStorageScreenState extends State<DeviceStorageScreen> {
  late Future<_DeviceStorageData> _future;
  final Set<String> _removingDeviceIds = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<String> _token() async {
    final token = await widget.storage.loadAuthToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(
        statusCode: 401,
        code: 'unauthorized',
        message: '登录状态已失效，请重新登录',
      );
    }
    return token;
  }

  Future<_DeviceStorageData> _load() async {
    final results = await Future.wait<Object?>([
      widget.gateway.loadStorageUsage(await _token()),
      widget.storage.loadDeviceId(),
    ]);
    return _DeviceStorageData(
      usage: results[0]! as StorageUsage,
      currentDeviceId: results[1] as String? ?? '',
    );
  }

  Future<void> _reload() async {
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  Future<void> _confirmRemove(DeviceStorageUsage device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除设备'),
        content: Text(
          '确定移除“${device.deviceName.isEmpty ? '未命名设备' : device.deviceName}”吗？\n\n'
          '此操作只移除这条空设备记录，不会删除服务器文件、同步目录或其他设备的数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_remove_device_button'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final currentDeviceId = await widget.storage.loadDeviceId() ?? '';
    if (!mounted) {
      return;
    }
    setState(() => _removingDeviceIds.add(device.deviceId));
    try {
      await widget.gateway.removeDevice(
        token: await _token(),
        deviceId: device.deviceId,
        currentDeviceId: currentDeviceId,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已移除 ${device.deviceName.isEmpty ? '空设备' : device.deviceName}',
          ),
        ),
      );
      await _reload();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userReadableErrorMessage(error))));
    } finally {
      if (mounted) {
        setState(() => _removingDeviceIds.remove(device.deviceId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备与空间'),
        actions: [
          IconButton(
            key: const ValueKey('refresh_device_storage_button'),
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<_DeviceStorageData>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return _DeviceStorageError(
              message: userReadableErrorMessage(snapshot.error!),
              onRetry: _reload,
            );
          }
          final data = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              key: const ValueKey('device_storage_list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _StorageOverview(usage: data.usage),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
                  child: Text(
                    '设备（${data.usage.devices.length}）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (data.usage.devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无已连接设备')),
                  )
                else
                  for (final device in data.usage.devices)
                    _DeviceUsageTile(
                      device: device,
                      isCurrent:
                          data.currentDeviceId.isNotEmpty &&
                          device.deviceId == data.currentDeviceId,
                      canRemove:
                          data.currentDeviceId.isNotEmpty &&
                          device.deviceId != data.currentDeviceId &&
                          device.syncRoots.isEmpty,
                      removing: _removingDeviceIds.contains(device.deviceId),
                      onRemove: () => _confirmRemove(device),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StorageOverview extends StatelessWidget {
  final StorageUsage usage;

  const _StorageOverview({required this.usage});

  @override
  Widget build(BuildContext context) {
    final ratio = usage.quotaBytes <= 0
        ? 0.0
        : (usage.usedBytes / usage.quotaBytes).clamp(0.0, 1.0);
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _OverviewValue(label: '设备', value: '${usage.devices.length} 台'),
              _OverviewValue(
                label: '已使用',
                value: _formatStorageBytes(usage.usedBytes),
              ),
              _OverviewValue(
                label: '总容量',
                value: _formatStorageBytes(usage.quotaBytes),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: ratio),
        ],
      ),
    );
  }
}

class _OverviewValue extends StatelessWidget {
  final String label;
  final String value;

  const _OverviewValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _DeviceUsageTile extends StatelessWidget {
  final DeviceStorageUsage device;
  final bool isCurrent;
  final bool canRemove;
  final bool removing;
  final VoidCallback onRemove;

  const _DeviceUsageTile({
    required this.device,
    required this.isCurrent,
    required this.canRemove,
    required this.removing,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name = device.deviceName.isEmpty ? '未命名设备' : device.deviceName;
    return Column(
      children: [
        ExpansionTile(
          key: ValueKey('device_usage_${device.deviceId}'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(24, 0, 16, 12),
          leading: Icon(_devicePlatformIcon(device.platform)),
          title: Row(
            children: [
              Expanded(
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (isCurrent) ...[
                const SizedBox(width: 8),
                const _CurrentDeviceBadge(),
              ],
            ],
          ),
          subtitle: Text(
            '${device.syncRoots.length} 个同步目录 · ${_formatStorageBytes(device.usedBytes)}',
          ),
          children: [
            if (device.syncRoots.isEmpty)
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.folder_off_outlined, size: 20),
                title: Text('暂无同步目录'),
                subtitle: Text('此设备没有关联的同步文件夹'),
              )
            else
              for (final root in device.syncRoots)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text('同步目录 ${_shortStorageId(root.syncRootId)}'),
                  subtitle: Text('${root.fileCount} 个文件'),
                  trailing: Text(_formatStorageBytes(root.usedBytes)),
                ),
            if (canRemove)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: ValueKey('remove_device_${device.deviceId}'),
                  onPressed: removing ? null : onRemove,
                  icon: removing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: Text(removing ? '正在移除' : '移除设备'),
                ),
              ),
          ],
        ),
        const Divider(height: 1, indent: 56),
      ],
    );
  }
}

class _CurrentDeviceBadge extends StatelessWidget {
  const _CurrentDeviceBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('当前', style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _DeviceStorageError extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _DeviceStorageError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceStorageData {
  final StorageUsage usage;
  final String currentDeviceId;

  const _DeviceStorageData({
    required this.usage,
    required this.currentDeviceId,
  });
}

String _formatStorageBytes(num value) {
  final bytes = value.toDouble();
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var amount = bytes;
  var unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  final digits = unit == 0 || amount >= 100 ? 0 : 1;
  return '${amount.toStringAsFixed(digits)} ${units[unit]}';
}

String _shortStorageId(String value) {
  return value.length <= 8 ? value : value.substring(0, 8);
}

IconData _devicePlatformIcon(String platform) {
  return switch (platform) {
    'android' || 'ios' => Icons.phone_android,
    'macos' || 'windows' || 'linux' => Icons.computer,
    _ => Icons.devices_other,
  };
}
