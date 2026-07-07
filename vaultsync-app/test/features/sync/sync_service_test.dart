import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/features/sync/sync_service.dart';

void main() {
  test('listSyncRoots loads sync roots with bearer token', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/sync-roots');
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {
                'items': [
                  {
                    'id': 'root-1',
                    'user_id': 'user-1',
                    'device_id': 'device-1',
                    'encrypted_path': 'base64:path',
                    'cleanup_policy': 'delete',
                    'archive_path': '',
                    'created_at': '2026-06-27T00:00:00Z',
                  },
                ],
              },
            }),
            200,
          );
        }),
      ),
    );

    final roots = await service.listSyncRoots(token: 'server-token');

    expect(roots, hasLength(1));
    expect(roots.single.id, 'root-1');
    expect(roots.single.encryptedPath, 'base64:path');
    expect(roots.single.cleanupPolicy, 'delete');
  });

  test('createSyncRoot posts root settings with bearer token', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/sync-roots');
          expect(request.headers['authorization'], 'Bearer server-token');
          expect(jsonDecode(request.body), {
            'device_id': 'device-1',
            'encrypted_path': 'base64:new-path',
            'cleanup_policy': 'archive',
            'archive_path': 'base64:archive-path',
          });
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {
                'id': 'root-2',
                'user_id': 'user-1',
                'device_id': 'device-1',
                'encrypted_path': 'base64:new-path',
                'cleanup_policy': 'archive',
                'archive_path': 'base64:archive-path',
                'created_at': '2026-06-27T01:00:00Z',
              },
            }),
            201,
          );
        }),
      ),
    );

    final root = await service.createSyncRoot(
      token: 'server-token',
      deviceId: 'device-1',
      encryptedPath: 'base64:new-path',
      cleanupPolicy: 'archive',
      archivePath: 'base64:archive-path',
    );

    expect(root.id, 'root-2');
    expect(root.deviceId, 'device-1');
    expect(root.encryptedPath, 'base64:new-path');
    expect(root.cleanupPolicy, 'archive');
    expect(root.archivePath, 'base64:archive-path');
  });

  test('updateSyncRootCleanupPolicy patches cleanup policy', () async {
    final service = SyncService(
      ApiClient(
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
              'data': {
                'id': 'root-1',
                'user_id': 'user-1',
                'device_id': 'device-1',
                'encrypted_path': 'base64:path',
                'cleanup_policy': 'delete',
                'archive_path': '',
                'created_at': '2026-07-01T00:00:00Z',
              },
            }),
            200,
          );
        }),
      ),
    );

    final root = await service.updateSyncRootCleanupPolicy(
      token: 'server-token',
      syncRootId: 'root-1',
      cleanupPolicy: 'delete',
    );

    expect(root.cleanupPolicy, 'delete');
  });

  test('deleteSyncRoot deletes root with remote content flag', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/v1/sync-roots/root-1');
          expect(request.url.queryParameters['delete_remote'], 'true');
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {'id': 'root-1', 'delete_remote': true},
            }),
            200,
          );
        }),
      ),
    );

    await service.deleteSyncRoot(
      token: 'server-token',
      syncRootId: 'root-1',
      deleteRemote: true,
    );
  });

  test('listChanges loads device scoped changes page', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/changes');
          expect(request.url.queryParameters, {
            'cursor': '42',
            'device_id': 'device-1',
            'limit': '50',
          });
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {
                'items': [
                  {
                    'change_type': 'upsert',
                    'version_id': 'version-1',
                    'object_id': 'object-1',
                    'sync_root_id': 'root-1',
                    'cursor_value': 43,
                    'encrypted_name': 'vaultsync-name:v1:name',
                    'content_hash': 'sha256:abc',
                    'size_bytes': 123,
                    'metadata_json': '{"nonce":"abc"}',
                    'created_at': '2026-06-27T01:00:00Z',
                  },
                ],
                'next_cursor': 43,
                'has_more': true,
              },
            }),
            200,
          );
        }),
      ),
    );

    final page = await service.listChanges(
      token: 'server-token',
      deviceId: 'device-1',
      cursor: 42,
      limit: 50,
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.id, 'version-1');
    expect(page.items.single.versionId, 'version-1');
    expect(page.items.single.objectId, 'object-1');
    expect(page.items.single.changeType, 'upsert');
    expect(page.items.single.encryptedName, 'vaultsync-name:v1:name');
    expect(page.items.single.contentHash, 'sha256:abc');
    expect(page.items.single.sizeBytes, 123);
    expect(page.items.single.metadataJson, '{"nonce":"abc"}');
    expect(page.nextCursor, 43);
    expect(page.hasMore, isTrue);
  });

  test('listRemoteBackupObjects loads server backup page', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/sync-roots/root-1/remote-objects');
          expect(request.url.queryParameters, {'cursor': '12', 'limit': '20'});
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 200,
              'data': {
                'items': [
                  {
                    'cursor_value': 13,
                    'sync_root_id': 'root-1',
                    'object_id': 'object-1',
                    'version_id': 'version-1',
                    'encrypted_name': 'vaultsync-name:v1:name',
                    'content_hash': 'sha256:abc',
                    'size_bytes': 123,
                    'metadata_json': '{"nonce":"abc"}',
                    'updated_at': '2026-07-01T01:00:00Z',
                  },
                ],
                'next_cursor': 13,
                'has_more': false,
              },
            }),
            200,
          );
        }),
      ),
    );

    final page = await service.listRemoteBackupObjects(
      token: 'server-token',
      syncRootId: 'root-1',
      cursor: 12,
      limit: 20,
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.cursorValue, 13);
    expect(page.items.single.syncRootId, 'root-1');
    expect(page.items.single.objectId, 'object-1');
    expect(page.items.single.versionId, 'version-1');
    expect(page.items.single.encryptedName, 'vaultsync-name:v1:name');
    expect(page.items.single.contentHash, 'sha256:abc');
    expect(page.items.single.sizeBytes, 123);
    expect(page.items.single.metadataJson, '{"nonce":"abc"}');
    expect(page.items.single.updatedAt, '2026-07-01T01:00:00Z');
    expect(page.nextCursor, 13);
    expect(page.hasMore, isFalse);
  });

  test('deleteRemoteObject creates remote delete tombstone', () async {
    final service = SyncService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/v1/objects/object-1');
          expect(request.url.queryParameters, {
            'sync_root_id': 'root-1',
            'device_id': 'device-1',
          });
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response(
            jsonEncode({
              'success': true,
              'message': '',
              'httpCode': 201,
              'data': {
                'id': 'tombstone-1',
                'change_type': 'delete',
                'object_id': 'object-1',
              },
            }),
            201,
          );
        }),
      ),
    );

    await service.deleteRemoteObject(
      token: 'server-token',
      deviceId: 'device-1',
      syncRootId: 'root-1',
      objectId: 'object-1',
    );
  });
}
