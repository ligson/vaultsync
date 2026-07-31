import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/preview/file_preview_screen.dart';
import 'package:vaultsync_app/features/preview/remote_file_preview.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('classifies common online preview formats', () {
    expect(remoteFilePreviewKindFor('photo.JPG'), RemoteFilePreviewKind.image);
    expect(remoteFilePreviewKindFor('clip.mp4'), RemoteFilePreviewKind.video);
    expect(remoteFilePreviewKindFor('manual.pdf'), RemoteFilePreviewKind.pdf);
    expect(remoteFilePreviewKindFor('notes.md'), RemoteFilePreviewKind.text);
    expect(remoteFilePreviewKindFor('archive.zip'), isNull);
  });

  test('downloads and decrypts a remote preview', () async {
    final downloads = _FakeDownloadGateway();
    final decrypter = _FakeDownloadPayloadDecrypter(
      const DecryptedRemoteObject(
        name: 'notes.txt',
        relativePath: 'docs/notes.txt',
        metadata: {},
        bytes: [104, 105],
      ),
    );
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: decrypter,
    );

    final data = await loader.load(
      token: 'token-1',
      entry: _entry(name: 'notes.txt'),
    );

    expect(data.kind, RemoteFilePreviewKind.text);
    expect(data.name, 'notes.txt');
    expect(data.bytes, orderedEquals([104, 105]));
    expect(downloads.token, 'token-1');
    expect(downloads.versionId, 'version-1');
    expect(decrypter.metadataJson, '{"format":"test"}');
    expect(decrypter.payloadBytes, orderedEquals([1, 2, 3]));
  });

  test('rejects oversized text before downloading', () async {
    final downloads = _FakeDownloadGateway();
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: _FakeDownloadPayloadDecrypter(
        const DecryptedRemoteObject(
          name: 'large.txt',
          relativePath: 'large.txt',
          metadata: {},
          bytes: [],
        ),
      ),
    );

    await expectLater(
      loader.load(
        token: 'token-1',
        entry: _entry(name: 'large.txt', sizeBytes: 6 * 1024 * 1024),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('在线预览上限为 5 MB'),
        ),
      ),
    );
    expect(downloads.callCount, 0);
  });

  testWidgets('text preview shows selectable decoded content', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FilePreviewScreen(
          fileName: 'notes.txt',
          loader: () async => RemoteFilePreviewData(
            name: 'notes.txt',
            kind: RemoteFilePreviewKind.text,
            bytes: Uint8List.fromList('VaultSync preview'.codeUnits),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('VaultSync preview'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('preview error can retry without leaving the page', (
    tester,
  ) async {
    var attempts = 0;
    final pendingRetry = Completer<RemoteFilePreviewData>();
    await tester.pumpWidget(
      MaterialApp(
        home: FilePreviewScreen(
          fileName: 'notes.txt',
          loader: () {
            attempts += 1;
            if (attempts == 1) {
              return Future.error(Exception('下载失败'));
            }
            return pendingRetry.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('下载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(attempts, 2);
    expect(find.text('正在安全下载并解密...'), findsOneWidget);
  });
}

RemoteBackupEntry _entry({required String name, int sizeBytes = 128}) {
  return RemoteBackupEntry(
    syncRootId: 'root-1',
    objectId: 'object-1',
    versionId: 'version-1',
    name: name,
    relativePath: name,
    sizeBytes: sizeBytes,
    updatedAt: '2026-07-31T00:00:00Z',
    encryptedName: 'encrypted-name',
    metadataJson: '{"format":"test"}',
  );
}

class _FakeDownloadGateway implements DownloadGateway {
  var callCount = 0;
  String? token;
  String? versionId;

  @override
  Future<DownloadedObject> downloadCiphertext({
    required String token,
    required String versionId,
    required String objectId,
    required String syncRootId,
    required String encryptedName,
  }) async {
    callCount += 1;
    this.token = token;
    this.versionId = versionId;
    return DownloadedObject(
      versionId: versionId,
      objectId: objectId,
      syncRootId: syncRootId,
      encryptedName: encryptedName,
      bytes: const [1, 2, 3],
    );
  }
}

class _FakeDownloadPayloadDecrypter implements DownloadPayloadDecrypter {
  final DecryptedRemoteObject result;
  String? metadataJson;
  List<int>? payloadBytes;

  _FakeDownloadPayloadDecrypter(this.result);

  @override
  Future<DecryptedRemoteObject> decrypt({
    required String syncRootId,
    required String objectId,
    required String versionId,
    required String encryptedName,
    required String metadataJson,
    required List<int> payloadBytes,
  }) async {
    this.metadataJson = metadataJson;
    this.payloadBytes = payloadBytes;
    return result;
  }
}
