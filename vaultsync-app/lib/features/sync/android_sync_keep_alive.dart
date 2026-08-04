import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidSyncKeepAlive {
  static const _channel = MethodChannel('vaultsync/background_sync');

  const AndroidSyncKeepAlive();

  Future<void> start(String platform) async {
    if (kIsWeb || platform != 'android') {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start');
    } on MissingPluginException {
      // Unit tests and non-Android embedders do not register this channel.
    } on PlatformException catch (error) {
      debugPrint('VaultSync background service start failed: $error');
    }
  }

  Future<void> stop(String platform) async {
    if (kIsWeb || platform != 'android') {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Unit tests and non-Android embedders do not register this channel.
    } on PlatformException catch (error) {
      debugPrint('VaultSync background service stop failed: $error');
    }
  }

  Future<void> setTransferActive(String platform, bool active) async {
    if (kIsWeb || platform != 'android') {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setTransferActive', {
        'active': active,
      });
    } on MissingPluginException {
      // Unit tests and non-Android embedders do not register this channel.
    } catch (error) {
      debugPrint('VaultSync upload wake lock update failed: $error');
    }
  }
}
