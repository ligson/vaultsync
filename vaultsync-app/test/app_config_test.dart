import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/config/app_config.dart';

void main() {
  test('AppConfig uses default API base url when env is empty', () {
    final config = AppConfig.fromEnvironment(const {});
    expect(config.apiBaseUrl.toString(), 'http://127.0.0.1:8080');
  });
}
