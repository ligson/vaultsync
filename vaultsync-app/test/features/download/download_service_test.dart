import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vaultsync_app/core/network/api_client.dart';
import 'package:vaultsync_app/features/download/download_service.dart';

void main() {
  test('downloadCiphertext loads object bytes with bearer token', () async {
    final service = DownloadService(
      ApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/objects/version-1');
          expect(request.headers['authorization'], 'Bearer server-token');
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'application/octet-stream'},
          );
        }),
      ),
    );

    final object = await service.downloadCiphertext(
      token: 'server-token',
      versionId: 'version-1',
      objectId: 'object-1',
      syncRootId: 'root-1',
      encryptedName: 'vaultsync-name:v1:name',
    );

    expect(object.versionId, 'version-1');
    expect(object.objectId, 'object-1');
    expect(object.syncRootId, 'root-1');
    expect(object.encryptedName, 'vaultsync-name:v1:name');
    expect(object.bytes, [1, 2, 3]);
  });

  test('downloadCiphertext propagates JSON envelope errors', () async {
    final service = DownloadService(
      ApiClient(
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
      ),
    );

    expect(
      () => service.downloadCiphertext(
        token: 'server-token',
        versionId: 'missing-version',
        objectId: 'object-1',
        syncRootId: 'root-1',
        encryptedName: 'vaultsync-name:v1:name',
      ),
      throwsException,
    );
  });
}
