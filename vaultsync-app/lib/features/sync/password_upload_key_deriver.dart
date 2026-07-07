import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'upload_key_store.dart';

class PasswordUploadKeyDeriver {
  static const defaultMemoryBlocks = 19 * 1024;
  static const defaultParallelism = 1;
  static const defaultIterations = 2;

  final int memoryBlocks;
  final int parallelism;
  final int iterations;

  const PasswordUploadKeyDeriver({
    this.memoryBlocks = defaultMemoryBlocks,
    this.parallelism = defaultParallelism,
    this.iterations = defaultIterations,
  });

  Future<UploadKeyMaterial> derive({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = normalizeEmail(email);
    final masterKey =
        await Argon2id(
          memory: memoryBlocks,
          parallelism: parallelism,
          iterations: iterations,
          hashLength: uploadKeyLength,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: utf8.encode('vaultsync:v1:upload-key:$normalizedEmail'),
        );
    final expandedKey =
        await Hkdf(
          hmac: Hmac.sha256(),
          outputLength: uploadKeyLength * 2,
        ).deriveKey(
          secretKey: masterKey,
          nonce: utf8.encode('vaultsync:v1:upload-key-hkdf'),
          info: utf8.encode('vaultsync:v1:content+metadata'),
        );
    final bytes = expandedKey.bytes;
    return UploadKeyMaterial(
      contentKeyBytes: bytes.sublist(0, uploadKeyLength),
      metadataKeyBytes: bytes.sublist(uploadKeyLength, uploadKeyLength * 2),
    );
  }

  String normalizeEmail(String email) => email.trim().toLowerCase();
}
