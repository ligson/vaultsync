import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import 'avatar_store.dart';

class ProfileScreen extends StatefulWidget {
  final SessionStore storage;
  final UserProfileGateway profileGateway;
  final AppReleaseGateway? releaseGateway;
  final AvatarStore avatarStore;
  final String platform;
  final String serverAddress;
  final Future<void> Function()? onConfigureServer;
  final Future<void> Function()? onSignOut;
  final Future<String> Function()? appVersionLoader;

  const ProfileScreen({
    super.key,
    required this.storage,
    required this.profileGateway,
    this.releaseGateway,
    required this.avatarStore,
    required this.platform,
    required this.serverAddress,
    this.onConfigureServer,
    this.onSignOut,
    this.appVersionLoader,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<UserProfile> _profileFuture;
  Future<Uint8List?> _avatarFuture = Future.value(null);
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
    _loadAppVersion();
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

  Future<UserProfile> _loadProfile() async {
    final profile = await widget.profileGateway.loadProfile(await _token());
    if (mounted) {
      setState(() {
        _avatarFuture = widget.avatarStore.load(profile.id);
      });
    }
    return profile;
  }

  Future<void> _loadAppVersion() async {
    final loader = widget.appVersionLoader;
    final version = loader != null
        ? await loader()
        : await PackageInfo.fromPlatform().then(
            (info) => '${info.version}+${info.buildNumber}',
          );
    if (mounted) {
      setState(() => _appVersion = version);
    }
  }

  Future<void> _refresh() async {
    final future = _loadProfile();
    setState(() {
      _profileFuture = future;
    });
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('我的')),
      body: FutureBuilder<UserProfile>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return _ProfileErrorView(
              message: userReadableErrorMessage(snapshot.error!),
              onRetry: _refresh,
            );
          }
          final profile = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              key: const ValueKey('profile_settings_list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _buildProfileHeader(profile),
                _buildStorageSummary(profile),
                _SectionLabel('账号与安全'),
                ListTile(
                  key: const ValueKey('edit_profile_tile'),
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('个人资料'),
                  subtitle: Text('@${profile.effectiveUsername}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editProfile(profile),
                ),
                ListTile(
                  key: const ValueKey('change_password_tile'),
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('修改密码'),
                  subtitle: const Text('使用当前密码验证身份'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePassword,
                ),
                const Divider(height: 1, indent: 56),
                _SectionLabel('存储与服务'),
                ListTile(
                  key: const ValueKey('storage_usage_tile'),
                  leading: const Icon(Icons.pie_chart_outline),
                  title: const Text('使用空间'),
                  subtitle: Text(
                    '${_formatBytes(profile.usedBytes)} / ${_formatBytes(profile.quotaBytes)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showStorageDetails(profile),
                ),
                ListTile(
                  key: const ValueKey('server_settings_tile'),
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器设置'),
                  subtitle: Text(
                    widget.serverAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onConfigureServer,
                ),
                const Divider(height: 1, indent: 56),
                _SectionLabel('应用'),
                ListTile(
                  key: const ValueKey('app_update_tile'),
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('App 更新'),
                  subtitle: Text(
                    _appVersion.isEmpty ? '正在读取版本' : '当前版本 $_appVersion',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _checkForUpdate,
                ),
                ListTile(
                  key: const ValueKey('about_tile'),
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于 VaultSync'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showAbout,
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: OutlinedButton.icon(
                    key: const ValueKey('sign_out_button'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onPressed: _confirmSignOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('退出登录'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildProfileHeader(UserProfile profile) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              FutureBuilder<Uint8List?>(
                future: _avatarFuture,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  return CircleAvatar(
                    key: const ValueKey('profile_avatar'),
                    radius: 36,
                    foregroundImage: bytes == null ? null : MemoryImage(bytes),
                    child: bytes == null
                        ? Text(
                            profile.displayName.characters.first.toUpperCase(),
                            style: Theme.of(context).textTheme.headlineSmall,
                          )
                        : null,
                  );
                },
              ),
              Positioned(
                right: -8,
                bottom: -8,
                child: IconButton.filledTonal(
                  key: const ValueKey('edit_avatar_button'),
                  tooltip: '更换头像',
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => _pickAvatar(profile),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  profile.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSummary(UserProfile profile) {
    final ratio = profile.quotaBytes <= 0
        ? 0.0
        : (profile.usedBytes / profile.quotaBytes).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined, size: 20),
              const SizedBox(width: 8),
              const Expanded(child: Text('云端空间')),
              Text('${(ratio * 100).toStringAsFixed(1)}%'),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: ratio, minHeight: 6),
          const SizedBox(height: 8),
          Text(
            '已使用 ${_formatBytes(profile.usedBytes)}，共 ${_formatBytes(profile.quotaBytes)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAvatar(UserProfile profile) async {
    const imageTypes = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: const [imageTypes]);
    if (file == null) {
      return;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      _showMessage('头像文件不能超过 5 MB');
      return;
    }
    try {
      await widget.avatarStore.save(profile.id, bytes);
      if (mounted) {
        setState(() {
          _avatarFuture = Future.value(bytes);
        });
      }
    } catch (error) {
      _showMessage(userReadableErrorMessage(error));
    }
  }

  Future<void> _editProfile(UserProfile profile) async {
    final username = TextEditingController(text: profile.effectiveUsername);
    final nickname = TextEditingController(text: profile.nickname);
    var saving = false;
    String? errorText;
    final updated = await showDialog<UserProfile>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑个人资料'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('nickname_field'),
                  controller: nickname,
                  maxLength: 32,
                  decoration: const InputDecoration(labelText: '昵称'),
                ),
                TextField(
                  key: const ValueKey('username_field'),
                  controller: username,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixText: '@',
                    helperText: '3-32 位小写字母、数字、点、短横线或下划线',
                  ),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('save_profile_button'),
              onPressed: saving
                  ? null
                  : () async {
                      setDialogState(() {
                        saving = true;
                        errorText = null;
                      });
                      try {
                        final value = await widget.profileGateway.updateProfile(
                          token: await _token(),
                          username: username.text,
                          nickname: nickname.text,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, value);
                        }
                      } catch (error) {
                        setDialogState(() {
                          saving = false;
                          errorText = userReadableErrorMessage(error);
                        });
                      }
                    },
              child: Text(saving ? '保存中' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() {
        _profileFuture = Future.value(updated);
      });
      _showMessage('个人资料已更新');
    }
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final password = TextEditingController();
    final confirmation = TextEditingController();
    var saving = false;
    String? errorText;
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('修改密码'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('current_password_field'),
                  controller: current,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
                TextField(
                  key: const ValueKey('new_password_field'),
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                ),
                TextField(
                  key: const ValueKey('confirm_password_field'),
                  controller: confirmation,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('save_password_button'),
              onPressed: saving
                  ? null
                  : () async {
                      if (password.text != confirmation.text) {
                        setDialogState(() => errorText = '两次输入的新密码不一致');
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        errorText = null;
                      });
                      try {
                        await widget.profileGateway.changePassword(
                          token: await _token(),
                          currentPassword: current.text,
                          newPassword: password.text,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      } catch (error) {
                        setDialogState(() {
                          saving = false;
                          errorText = userReadableErrorMessage(error);
                        });
                      }
                    },
              child: Text(saving ? '保存中' : '确认修改'),
            ),
          ],
        ),
      ),
    );
    if (changed == true) {
      _showMessage('密码已更新');
    }
  }

  Future<void> _checkForUpdate() async {
    final gateway = widget.releaseGateway;
    if (gateway == null) {
      _showMessage('当前环境未配置更新服务');
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final release = await gateway.loadRelease(widget.platform);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await _showRelease(release);
      }
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showMessage(userReadableErrorMessage(error));
      }
    }
  }

  Future<void> _showRelease(AppRelease release) async {
    final updateAvailable = _compareVersions(release.version, _appVersion) > 0;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(updateAvailable ? '发现新版本' : '已是最新版本'),
        content: Text(
          updateAvailable
              ? '最新版本 ${release.version}\n安装包 ${_formatBytes(release.sizeBytes)}'
              : '当前版本 $_appVersion\n服务器版本 ${release.version}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          if (updateAvailable && release.downloadUrl.isNotEmpty)
            FilledButton.icon(
              onPressed: () async {
                final uri = Uri.tryParse(release.downloadUrl);
                if (uri == null ||
                    !await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    )) {
                  _showMessage('无法打开下载地址');
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('下载'),
            ),
        ],
      ),
    );
  }

  void _showStorageDetails(UserProfile profile) {
    final remaining = (profile.quotaBytes - profile.usedBytes).clamp(
      0,
      profile.quotaBytes,
    );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用空间'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ValueRow(label: '已使用', value: _formatBytes(profile.usedBytes)),
            _ValueRow(label: '可用', value: _formatBytes(remaining)),
            _ValueRow(label: '总容量', value: _formatBytes(profile.quotaBytes)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'VaultSync',
      applicationVersion: _appVersion,
      applicationIcon: const Icon(Icons.shield_outlined, size: 42),
      children: const [Text('面向个人 NAS 的端到端加密文件同步工具。服务器只保存密文，解密密钥保留在客户端。')],
    );
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('本地目录绑定、上传队列、同步记录和加密密钥会继续保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_sign_out_button'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.onSignOut?.call();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  final String label;
  final String value;

  const _ValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _ProfileErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ProfileErrorView({required this.message, required this.onRetry});

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

String _formatBytes(num value) {
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

int _compareVersions(String left, String right) {
  List<int> parts(String value) => RegExp(
    r'\d+',
  ).allMatches(value).map((match) => int.parse(match.group(0)!)).toList();
  final a = parts(left);
  final b = parts(right);
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index += 1) {
    final av = index < a.length ? a[index] : 0;
    final bv = index < b.length ? b[index] : 0;
    if (av != bv) {
      return av.compareTo(bv);
    }
  }
  return 0;
}
