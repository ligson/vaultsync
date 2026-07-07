import 'package:flutter/material.dart';

import '../../core/device/device_profile.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/app_storage.dart';
import 'auth_service.dart';
import '../device/device_service.dart';
import '../media_backup/media_backup_gateway.dart';
import '../sync/local_upload_executor.dart';
import '../sync/remote_metadata_decrypter.dart';
import '../sync/sync_home_screen.dart';
import '../sync/sync_pull_executor.dart';
import '../sync/sync_service.dart';
import '../sync/upload_key_store.dart';

class LoginScreen extends StatefulWidget {
  final AuthGateway auth;
  final DeviceGateway devices;
  final SessionStore storage;
  final SyncRootMappingStore syncRootMappings;
  final UploadTaskStore uploadTasks;
  final SyncIssueStore? syncIssues;
  final AutoSyncStatusStore? autoSyncStatus;
  final SyncHistoryStore? syncHistory;
  final UploadKeyStore uploadKeys;
  final DeviceProfile deviceProfile;
  final SyncRootGateway syncRoots;
  final LocalUploadExecutionGateway? uploadExecutor;
  final RemoteSyncPullGateway? remotePullExecutor;
  final RemoteBackupGateway? remoteBackups;
  final RemoteObjectDeleteGateway? remoteObjectDeletes;
  final RemoteMetadataDecrypter? remoteMetadataDecrypter;
  final MediaBackupSourceStore? mediaBackupSources;
  final MediaBackupGateway? mediaGateway;
  final bool autoSyncEnabled;
  final Future<void> Function()? onSignOut;
  final String? serverAddress;
  final Future<void> Function(String address)? onServerAddressChanged;
  final Future<void> Function(String address)? onTestServerConnection;

  const LoginScreen({
    super.key,
    required this.auth,
    required this.devices,
    required this.storage,
    required this.syncRootMappings,
    required this.uploadTasks,
    this.syncIssues,
    this.autoSyncStatus,
    this.syncHistory,
    required this.uploadKeys,
    required this.deviceProfile,
    required this.syncRoots,
    this.uploadExecutor,
    this.remotePullExecutor,
    this.remoteBackups,
    this.remoteObjectDeletes,
    this.remoteMetadataDecrypter,
    this.mediaBackupSources,
    this.mediaGateway,
    this.autoSyncEnabled = false,
    this.onSignOut,
    this.serverAddress,
    this.onServerAddressChanged,
    this.onTestServerConnection,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VaultSync'),
        actions: [
          IconButton(
            key: const ValueKey('login_server_settings_button'),
            tooltip: '服务器设置',
            onPressed: _openServerSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('login_email_field'),
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: '邮箱'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('login_password_field'),
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                  onSubmitted: (_) => _submit(),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('login_submit_button'),
                  onPressed: _isSubmitting ? null : _submit,
                  child: Text(_isSubmitting ? '登录中...' : '登录'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('login_register_button'),
                  onPressed: _isSubmitting ? null : _registerAndLogin,
                  child: Text(_isSubmitting ? '处理中...' : '注册账号'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openServerSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ServerSettingsDialog(
        serverAddress: widget.serverAddress ?? '',
        auth: widget.auth,
        onServerAddressChanged: widget.onServerAddressChanged,
        onTestServerConnection: widget.onTestServerConnection,
      ),
    );
  }

  Future<void> _registerAndLogin() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      await widget.auth.register(email, password);
      await _openSession(email: email, password: password);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = userReadableErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      await _openSession(email: email, password: password);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = userReadableErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _openSession({
    required String email,
    required String password,
  }) async {
    final session = await widget.auth.login(email, password);
    final device = await widget.devices.registerDevice(
      token: session.token,
      name: widget.deviceProfile.name,
      platform: widget.deviceProfile.platform,
    );
    await widget.uploadKeys.deriveAndSaveUploadKeys(
      email: email,
      password: password,
    );
    await widget.storage.saveAuthSession(session);
    await widget.storage.saveDevice(device);
    if (!mounted) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SyncHomeScreen(
          storage: widget.storage,
          syncRootMappings: widget.syncRootMappings,
          uploadTasks: widget.uploadTasks,
          syncIssues: widget.syncIssues,
          autoSyncStatus: widget.autoSyncStatus,
          syncHistory: widget.syncHistory,
          syncRoots: widget.syncRoots,
          uploadExecutor: widget.uploadExecutor,
          remotePullExecutor: widget.remotePullExecutor,
          remoteBackups: widget.remoteBackups,
          remoteObjectDeletes: widget.remoteObjectDeletes,
          remoteMetadataDecrypter: widget.remoteMetadataDecrypter,
          mediaBackupSources: widget.mediaBackupSources,
          mediaGateway: widget.mediaGateway,
          devicePlatform: widget.deviceProfile.platform,
          autoSyncEnabled: widget.autoSyncEnabled,
          onSignOut: widget.onSignOut,
        ),
      ),
    );
  }
}

class _ServerSettingsDialog extends StatefulWidget {
  final String serverAddress;
  final AuthGateway auth;
  final Future<void> Function(String address)? onServerAddressChanged;
  final Future<void> Function(String address)? onTestServerConnection;

  const _ServerSettingsDialog({
    required this.serverAddress,
    required this.auth,
    this.onServerAddressChanged,
    this.onTestServerConnection,
  });

  @override
  State<_ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<_ServerSettingsDialog> {
  late final TextEditingController _controller;
  bool _isTesting = false;
  bool _isSaving = false;
  String? _statusMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.serverAddress);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('服务器设置'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('server_address_field'),
                controller: _controller,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: '后端地址'),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving || _isTesting
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('server_settings_test_button'),
          onPressed: _isSaving || _isTesting ? null : _testConnection,
          icon: const Icon(Icons.cloud_done_outlined),
          label: Text(_isTesting ? '连接中...' : '测试连接'),
        ),
        FilledButton(
          key: const ValueKey('server_settings_save_button'),
          onPressed: _isSaving || _isTesting ? null : _saveAddress,
          child: Text(_isSaving ? '保存中...' : '保存'),
        ),
      ],
    );
  }

  Future<void> _testConnection() async {
    final address = _controller.text.trim();
    final validationMessage = _validateServerAddress(address);
    if (validationMessage != null) {
      setState(() {
        _statusMessage = null;
        _errorMessage = validationMessage;
      });
      return;
    }
    setState(() {
      _isTesting = true;
      _statusMessage = null;
      _errorMessage = null;
    });
    try {
      final test = widget.onTestServerConnection;
      if (test != null) {
        await test(address);
      } else {
        await widget.auth.ping();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '后端连接正常';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = userReadableErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  Future<void> _saveAddress() async {
    final address = _controller.text.trim();
    final validationMessage = _validateServerAddress(address);
    if (validationMessage != null) {
      setState(() {
        _statusMessage = null;
        _errorMessage = validationMessage;
      });
      return;
    }
    setState(() {
      _isSaving = true;
      _statusMessage = null;
      _errorMessage = null;
    });
    try {
      await widget.onServerAddressChanged?.call(address);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = userReadableErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String? _validateServerAddress(String address) {
    if (address.isEmpty) {
      return '后端地址不能为空';
    }
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '请输入有效的后端地址，例如 http://127.0.0.1:8080';
    }
    return null;
  }
}
