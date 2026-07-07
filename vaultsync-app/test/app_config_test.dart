import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/config/app_config.dart';

void main() {
  test('AppConfig uses local API base url by default in debug builds', () {
    final config = AppConfig.fromEnvironment(const {}, isRelease: false);
    expect(config.apiBaseUrl.toString(), 'http://127.0.0.1:8080');
  });

  test('AppConfig uses production API base url by default in release builds', () {
    final config = AppConfig.fromEnvironment(const {}, isRelease: true);
    expect(config.apiBaseUrl.toString(), 'https://files.ligson.xyz');
  });

  test('AppConfig keeps explicit API base url as highest priority', () {
    final config = AppConfig.fromEnvironment(
      const {'VAULTSYNC_API_BASE_URL': 'https://custom.example.com'},
      isRelease: true,
    );
    expect(config.apiBaseUrl.toString(), 'https://custom.example.com');
  });
}
