import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/features/auth/auth_service.dart';

void main() {
  test('register posts credentials and returns registered user', () async {
    final service = AuthService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/auth/register');
          expect(jsonDecode(request.body), {
            'email': 'alice@example.com',
            'password': 'passw0rd!',
          });
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {'id': 'user-1', 'email': 'alice@example.com'},
            }),
            201,
          );
        }),
      ),
    );

    final user = await service.register('alice@example.com', 'passw0rd!');

    expect(user.id, 'user-1');
    expect(user.email, 'alice@example.com');
  });

  test('login posts credentials and returns auth session', () async {
    final service = AuthService(
      ApiClient(
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
              'data': {
                'token': 'server-token',
                'token_id': 'token-1',
                'user_id': 'user-1',
                'expires_at': '2026-06-28T00:00:00Z',
              },
            }),
            200,
          );
        }),
      ),
    );

    final session = await service.login('alice@example.com', 'passw0rd!');

    expect(session.token, 'server-token');
    expect(session.tokenId, 'token-1');
    expect(session.userId, 'user-1');
    expect(session.expiresAt, '2026-06-28T00:00:00Z');
  });

  test('refresh posts bearer token and returns renewed auth session', () async {
    final service = AuthService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/auth/refresh');
          expect(request.headers['authorization'], 'Bearer old-token');
          expect(jsonDecode(request.body), {});
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {
                'token': 'new-token',
                'token_id': 'token-2',
                'user_id': 'user-1',
                'expires_at': '2026-06-29T00:00:00Z',
              },
            }),
            200,
          );
        }),
      ),
    );

    final session = await service.refresh('old-token');

    expect(session.token, 'new-token');
    expect(session.tokenId, 'token-2');
    expect(session.expiresAt, '2026-06-29T00:00:00Z');
  });

  test('ping checks backend health endpoint', () async {
    final service = AuthService(
      ApiClient(
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
          );
        }),
      ),
    );

    await service.ping();
  });
}
