import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/features/device/device_service.dart';

void main() {
  test('registerDevice posts device info with bearer token', () async {
    final service = DeviceService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/devices');
          expect(request.headers['authorization'], 'Bearer server-token');
          expect(jsonDecode(request.body), {
            'name': 'Alice iPhone',
            'platform': 'ios',
          });
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {
                'id': 'device-1',
                'user_id': 'user-1',
                'name': 'Alice iPhone',
                'platform': 'ios',
                'created_at': '2026-06-27T00:00:00Z',
              },
            }),
            201,
          );
        }),
      ),
    );

    final device = await service.registerDevice(
      token: 'server-token',
      name: 'Alice iPhone',
      platform: 'ios',
    );

    expect(device.id, 'device-1');
    expect(device.userId, 'user-1');
    expect(device.name, 'Alice iPhone');
    expect(device.platform, 'ios');
  });
}
