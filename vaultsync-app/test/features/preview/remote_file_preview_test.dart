import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, ECBBlockCipher, KeyParameter;
import 'package:vaultsync_app/features/download/download_models.dart';
import 'package:vaultsync_app/features/download/download_service.dart';
import 'package:vaultsync_app/features/preview/file_preview_screen.dart';
import 'package:vaultsync_app/features/preview/remote_file_preview.dart';
import 'package:vaultsync_app/features/sync/encrypted_download_payload_decrypter.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';
import 'package:vaultsync_app/features/sync/wechat_dat_decoder.dart';

void main() {
  test('classifies common online preview formats', () {
    expect(remoteFilePreviewKindFor('photo.JPG'), RemoteFilePreviewKind.image);
    expect(remoteFilePreviewKindFor('clip.mp4'), RemoteFilePreviewKind.video);
    expect(remoteFilePreviewKindFor('manual.pdf'), RemoteFilePreviewKind.pdf);
    expect(remoteFilePreviewKindFor('notes.md'), RemoteFilePreviewKind.text);
    expect(remoteFilePreviewKindFor('archive.zip'), isNull);
    expect(
      remoteFilePreviewKindForBytes(
        Uint8List.fromList(base64Decode(_onePixelPngBase64)),
      ),
      RemoteFilePreviewKind.image,
    );
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

  test(
    'probes extensionless WeChat attachment preview by file signature',
    () async {
      final downloads = _FakeDownloadGateway();
      final decrypter = _FakeDownloadPayloadDecrypter(
        DecryptedRemoteObject(
          name: '2afc89b67185a80d7',
          relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
          metadata: const {},
          bytes: base64Decode(_onePixelPngBase64),
        ),
      );
      final loader = RemoteFilePreviewLoader(
        downloads: downloads,
        decrypter: decrypter,
      );

      final data = await loader.load(
        token: 'token-1',
        entry: _entry(
          name: '2afc89b67185a80d7',
          relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
        ),
      );

      expect(data.kind, RemoteFilePreviewKind.image);
      expect(downloads.callCount, 1);
    },
  );

  test('decodes historical extensionless WeChat dat image preview', () async {
    final plainBytes = base64Decode(_onePixelPngBase64);
    const xorKey = 0x5a;
    final downloads = _FakeDownloadGateway();
    final decrypter = _FakeDownloadPayloadDecrypter(
      DecryptedRemoteObject(
        name: '2afc89b67185a80d7',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
        metadata: const {},
        bytes: [for (final byte in plainBytes) byte ^ xorKey],
      ),
    );
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: decrypter,
    );

    final data = await loader.load(
      token: 'token-1',
      entry: _entry(
        name: '2afc89b67185a80d7',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7',
      ),
    );

    expect(data.kind, RemoteFilePreviewKind.image);
    expect(data.bytes, orderedEquals(plainBytes));
  });

  test('decodes historical WeChat dat attachment preview', () async {
    final plainBytes = base64Decode(_onePixelPngBase64);
    const xorKey = 0x5a;
    final downloads = _FakeDownloadGateway();
    final decrypter = _FakeDownloadPayloadDecrypter(
      DecryptedRemoteObject(
        name: '2afc89b67185a80d7.dat',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7.dat',
        metadata: const {},
        bytes: [for (final byte in plainBytes) byte ^ xorKey],
      ),
    );
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: decrypter,
    );

    final data = await loader.load(
      token: 'token-1',
      entry: _entry(
        name: '2afc89b67185a80d7.dat',
        relativePath: 'msg/attach/00edbf/2afc89b67185a80d7.dat',
      ),
    );

    expect(data.kind, RemoteFilePreviewKind.image);
    expect(data.bytes, orderedEquals(plainBytes));
  });

  test('explains unsupported WeChat v2 dat attachment preview', () async {
    final downloads = _FakeDownloadGateway();
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: _FakeDownloadPayloadDecrypter(
        const DecryptedRemoteObject(
          name: '2afc89b67185a80d728503b08aa9c5cc.dat',
          relativePath:
              'tianlang519241_5b3c/msg/attach/00edbf/2026-02/Img/2afc89b67185a80d728503b08aa9c5cc.dat',
          metadata: {},
          bytes: [
            0x07,
            0x08,
            0x56,
            0x32,
            0x08,
            0x07,
            0x00,
            0x04,
            0x00,
            0x00,
            0xca,
            0x7a,
            0x01,
            0x00,
          ],
        ),
      ),
    );

    await expectLater(
      loader.load(
        token: 'token-1',
        entry: _entry(
          name: '2afc89b67185a80d728503b08aa9c5cc.dat',
          relativePath:
              'tianlang519241_5b3c/msg/attach/00edbf/2026-02/Img/2afc89b67185a80d728503b08aa9c5cc.dat',
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          allOf(contains('文件已在服务器备份'), contains('微信新版加密 dat 图片')),
        ),
      ),
    );
    expect(downloads.callCount, 1);
  });

  test('decodes WeChat v2 dat attachment when image key is available', () async {
    final aesKey = List<int>.generate(16, (index) => index + 1);
    const xorKey = 0x3a;
    final datBytes = _wechatDatV2JpegBytes(aesKey: aesKey, xorKey: xorKey);
    final downloads = _FakeDownloadGateway();
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: _FakeDownloadPayloadDecrypter(
        DecryptedRemoteObject(
          name: '2afc89b67185a80d728503b08aa9c5cc.dat',
          relativePath:
              'tianlang519241_5b3c/msg/attach/00edbf/2026-02/Img/2afc89b67185a80d728503b08aa9c5cc.dat',
          metadata: const {},
          bytes: datBytes,
        ),
      ),
      wechatDatV2ImageKeys: _FakeWechatDatV2ImageKeyProvider(
        WechatDatV2ImageKey(aesKey: aesKey, xorKey: xorKey),
      ),
    );

    final data = await loader.load(
      token: 'token-1',
      entry: _entry(
        name: '2afc89b67185a80d728503b08aa9c5cc.dat',
        relativePath:
            'tianlang519241_5b3c/msg/attach/00edbf/2026-02/Img/2afc89b67185a80d728503b08aa9c5cc.dat',
      ),
    );

    expect(data.kind, RemoteFilePreviewKind.image);
    expect(data.bytes, orderedEquals(_jpegBytes));
    expect(downloads.callCount, 1);
  });

  test('does not probe arbitrary extensionless remote files', () async {
    final downloads = _FakeDownloadGateway();
    final loader = RemoteFilePreviewLoader(
      downloads: downloads,
      decrypter: _FakeDownloadPayloadDecrypter(
        const DecryptedRemoteObject(
          name: 'unknown',
          relativePath: 'unknown',
          metadata: {},
          bytes: [],
        ),
      ),
    );

    await expectLater(
      loader.load(
        token: 'token-1',
        entry: _entry(name: 'unknown'),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('暂不支持预览此文件格式'),
        ),
      ),
    );
    expect(downloads.callCount, 0);
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

RemoteBackupEntry _entry({
  required String name,
  String? relativePath,
  int sizeBytes = 128,
}) {
  return RemoteBackupEntry(
    syncRootId: 'root-1',
    objectId: 'object-1',
    versionId: 'version-1',
    name: name,
    relativePath: relativePath ?? name,
    sizeBytes: sizeBytes,
    updatedAt: '2026-07-31T00:00:00Z',
    encryptedName: 'encrypted-name',
    metadataJson: '{"format":"test"}',
  );
}

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axl3ToAAAAASUVORK5CYII=';

const _jpegBytes = [
  0xff,
  0xd8,
  0xff,
  0xe0,
  0x00,
  0x10,
  0x4a,
  0x46,
  0x49,
  0x46,
  0xff,
  0xd9,
];

List<int> _wechatDatV2JpegBytes({
  required List<int> aesKey,
  required int xorKey,
}) {
  final encryptedPrefix = _encryptAesEcb([
    ..._jpegBytes.take(10),
    ...List<int>.filled(6, 6),
  ], aesKey);
  final tail = _jpegBytes.sublist(10);
  return [
    0x07,
    0x08,
    0x56,
    0x32,
    0x08,
    0x07,
    ..._uint32LittleEndian(10),
    ..._uint32LittleEndian(tail.length),
    0x01,
    ...encryptedPrefix,
    for (final byte in tail) byte ^ xorKey,
  ];
}

List<int> _encryptAesEcb(List<int> bytes, List<int> aesKey) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(aesKey)));
  final input = Uint8List.fromList(bytes);
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += cipher.blockSize) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

List<int> _uint32LittleEndian(int value) {
  return [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];
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

class _FakeWechatDatV2ImageKeyProvider implements WechatDatV2ImageKeyProvider {
  final WechatDatV2ImageKey? key;

  const _FakeWechatDatV2ImageKeyProvider(this.key);

  @override
  Future<WechatDatV2ImageKey?> loadImageKey({
    required String name,
    required String relativePath,
    required List<int> bytes,
  }) async {
    return key;
  }
}
