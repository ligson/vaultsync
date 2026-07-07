import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/core/network/api_exception.dart';
import 'package:vaultsync_app/core/storage/app_storage.dart';
import 'package:vaultsync_app/features/auth/auth_models.dart';
import 'package:vaultsync_app/features/device/device_models.dart';

void main() {
  test('post decodes successful JSON envelope data', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/auth/login');
        expect(jsonDecode(request.body), {
          'email': 'alice@example.com',
          'password': 'passw0rd!',
        });
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'token': 'server-token'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await client.post(
      '/api/v1/auth/login',
      body: const {'email': 'alice@example.com', 'password': 'passw0rd!'},
    );

    expect(data, {'token': 'server-token'});
  });

  test('post throws ApiException from failed envelope', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'message': 'invalid email or password',
            'httpCode': 401,
            'data': {'code': 'unauthorized'},
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(
      () => client.post('/api/v1/auth/login', body: const {}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.code, 'code', 'unauthorized')
            .having((e) => e.message, 'message', 'invalid email or password'),
      ),
    );
  });

  test('get sends bearer token when provided', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer token-1');
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'items': <Object>[]},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await client.get('/api/v1/sync-roots', token: 'token-1');

    expect(data, {'items': <Object>[]});
  });

  test('patch sends bearer token and decodes envelope', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/api/v1/sync-roots/root-1');
        expect(request.headers['authorization'], 'Bearer server-token');
        expect(jsonDecode(request.body), {'cleanup_policy': 'delete'});
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'id': 'root-1'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await client.patch(
      '/api/v1/sync-roots/root-1',
      token: 'server-token',
      body: const {'cleanup_policy': 'delete'},
    );

    expect(data['id'], 'root-1');
  });

  test('delete sends bearer token and decodes envelope', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/sync-roots/root-1');
        expect(request.url.queryParameters['delete_remote'], 'false');
        expect(request.headers['authorization'], 'Bearer server-token');
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'id': 'root-1', 'delete_remote': false},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final data = await client.delete(
      '/api/v1/sync-roots/root-1?delete_remote=false',
      token: 'server-token',
    );

    expect(data['delete_remote'], false);
  });

  test('get throws readable ApiException for empty response body', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        return http.Response('', 500);
      }),
    );

    expect(
      () => client.get('/api/v1/changes', token: 'token-1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.code, 'code', 'empty_response')
            .having(
              (e) => e.message,
              'message',
              '后端服务没有返回有效内容，请确认 VaultSync 后端已启动并且地址正确',
            ),
      ),
    );
  });

  test('ping checks health endpoint', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/health');
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'status': 'ok'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.ping();
  });

  test('ping throws readable connection failure', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        throw http.ClientException('connection refused');
      }),
    );

    expect(
      client.ping,
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 0)
            .having((e) => e.code, 'code', 'connection_failed')
            .having(
              (e) => e.message,
              'message',
              '无法连接后端服务，请确认 VaultSync 后端已启动，或检查后端地址是否正确',
            ),
      ),
    );
  });

  test('get throws readable ApiException for non-json response body', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        return http.Response('<html>bad gateway</html>', 502);
      }),
    );

    expect(
      () => client.get('/api/v1/changes', token: 'token-1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.code, 'code', 'invalid_response')
            .having(
              (e) => e.message,
              'message',
              '服务器返回了无法解析的响应，请确认 API 地址和后端服务状态',
            ),
      ),
    );
  });

  test('putBytes sends binary body with bearer token', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/v1/upload-sessions/session-1/parts/0');
        expect(request.headers['authorization'], 'Bearer token-1');
        expect(request.headers['content-type'], 'application/octet-stream');
        expect(request.bodyBytes, [1, 2, 3]);
        return http.Response('', 204);
      }),
    );

    await client.putBytes(
      '/api/v1/upload-sessions/session-1/parts/0',
      bytes: const [1, 2, 3],
      token: 'token-1',
    );
  });

  test('getBytes returns binary body with bearer token', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/objects/version-1');
        expect(request.headers['authorization'], 'Bearer token-1');
        expect(request.headers['accept'], 'application/octet-stream');
        return http.Response.bytes(
          [9, 8, 7],
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }),
    );

    final bytes = await client.getBytes(
      '/api/v1/objects/version-1',
      token: 'token-1',
    );

    expect(bytes, [9, 8, 7]);
  });

  test('getBytes throws ApiException from failed JSON envelope', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'message': 'object version not found',
            'httpCode': 404,
            'data': {'code': 'not_found'},
          }),
          404,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(
      () => client.getBytes('/api/v1/objects/version-404', token: 'token-1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.code, 'code', 'not_found')
            .having((e) => e.message, 'message', 'object version not found'),
      ),
    );
  });

  test('get refreshes token on 401 and retries once', () async {
    final requestedTokens = <String?>[];
    final store = FakeSessionStore();
    final client = ApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      sessionStore: store,
      refreshAuthSession: (token) async {
        expect(token, 'old-token');
        return const AuthSession(
          token: 'new-token',
          tokenId: 'token-id-2',
          userId: 'user-1',
          expiresAt: '2999-01-01T00:00:00Z',
        );
      },
      httpClient: MockClient((request) async {
        requestedTokens.add(request.headers['authorization']);
        if (requestedTokens.length == 1) {
          return http.Response(
            jsonEncode({
              'success': false,
              'message': 'invalid bearer token',
              'httpCode': 401,
              'data': {'code': 'unauthorized'},
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode({
            'success': true,
            'message': '',
            'httpCode': 200,
            'data': {'items': <Object>[]},
          }),
          200,
        );
      }),
    );

    final data = await client.get('/api/v1/sync-roots', token: 'old-token');

    expect(data, {'items': <Object>[]});
    expect(requestedTokens, ['Bearer old-token', 'Bearer new-token']);
    expect(store.savedSession?.token, 'new-token');
  });
}

class FakeSessionStore implements SessionStore {
  AuthSession? savedSession;

  @override
  Future<String?> loadAuthToken() async => savedSession?.token;

  @override
  Future<String?> loadAuthExpiresAt() async => savedSession?.expiresAt;

  @override
  Future<String?> loadDeviceId() async => 'device-1';

  @override
  Future<void> saveAuthSession(AuthSession session) async {
    savedSession = session;
  }

  @override
  Future<void> saveDevice(RegisteredDevice device) async {}
}
