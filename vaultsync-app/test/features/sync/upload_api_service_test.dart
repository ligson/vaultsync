import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/features/sync/upload_api_service.dart';

void main() {
  test('createUploadSession posts upload metadata', () async {
    final service = UploadApiService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/upload-sessions');
          expect(request.headers['authorization'], 'Bearer server-token');
          expect(jsonDecode(request.body), {
            'device_id': 'device-1',
            'sync_root_id': 'root-1',
            'object_id': 'object-1',
            'version_id': 'version-1',
            'total_size': 3,
            'chunk_size': 3,
            'encrypted_name': 'enc:a.jpg',
            'metadata_json': '{"relative_path":"a.jpg"}',
          });
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {
                'id': 'session-1',
                'user_id': 'user-1',
                'device_id': 'device-1',
                'sync_root_id': 'root-1',
                'object_id': 'object-1',
                'version_id': 'version-1',
                'encrypted_name': 'enc:a.jpg',
                'total_size': 3,
                'chunk_size': 3,
                'received_size': 0,
                'status': 'pending',
                'metadata_json': '{"relative_path":"a.jpg"}',
                'created_at': '2026-06-27T10:00:00Z',
              },
            }),
            201,
          );
        }),
      ),
    );

    final session = await service.createUploadSession(
      token: 'server-token',
      deviceId: 'device-1',
      syncRootId: 'root-1',
      objectId: 'object-1',
      versionId: 'version-1',
      totalSize: 3,
      chunkSize: 3,
      encryptedName: 'enc:a.jpg',
      metadataJson: '{"relative_path":"a.jpg"}',
    );

    expect(session.id, 'session-1');
    expect(session.status, 'pending');
  });

  test('uploadPart and complete call upload session endpoints', () async {
    final requestedPaths = <String>[];
    final service = UploadApiService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          requestedPaths.add('${request.method} ${request.url.path}');
          if (request.method == 'PUT') {
            expect(request.bodyBytes, [1, 2, 3]);
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {
                'id': 'version-1',
                'user_id': 'user-1',
                'sync_root_id': 'root-1',
                'object_id': 'object-1',
                'encrypted_name': 'enc:a.jpg',
                'content_path': 'objects/version-1',
                'content_hash': 'sha256:abc',
                'size_bytes': 3,
                'metadata_json': '{}',
                'created_at': '2026-06-27T10:01:00Z',
              },
            }),
            201,
          );
        }),
      ),
    );

    await service.uploadPart(
      token: 'server-token',
      sessionId: 'session-1',
      partIndex: 0,
      bytes: const [1, 2, 3],
    );
    final version = await service.completeUploadSession(
      token: 'server-token',
      sessionId: 'session-1',
    );

    expect(requestedPaths, [
      'PUT /api/v1/upload-sessions/session-1/parts/0',
      'POST /api/v1/upload-sessions/session-1/complete',
    ]);
    expect(version.id, 'version-1');
  });

  test('getUploadSession reads received upload progress', () async {
    final service = UploadApiService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/upload-sessions/session-1');
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {
                'id': 'session-1',
                'total_size': 7,
                'chunk_size': 3,
                'received_size': 3,
                'status': 'pending',
              },
            }),
            200,
          );
        }),
      ),
    );

    final session = await service.getUploadSession(
      token: 'server-token',
      sessionId: 'session-1',
    );

    expect(session.id, 'session-1');
    expect(session.totalSize, 7);
    expect(session.chunkSize, 3);
    expect(session.receivedSize, 3);
  });
}
