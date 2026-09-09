import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';

/// Encrypts the small display name while keeping the server unaware of it.
class SyncRootDisplayNameProtector {
  static const _prefix = 'vaultsync-root-name:v1:';
  static const _nonceLength = 24;

  final Cipher cipher;
  final math.Random random;

  SyncRootDisplayNameProtector({Cipher? cipher, math.Random? random})
    : cipher = cipher ?? Xchacha20.poly1305Aead(),
      random = random ?? math.Random.secure();

  Future<String> encrypt({
    required String displayName,
    required String encryptedPath,
    required List<int> keyBytes,
  }) async {
    final nonce = List<int>.generate(_nonceLength, (_) => random.nextInt(256));
    final box = await cipher.encrypt(
      utf8.encode(displayName),
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: _aad(encryptedPath),
    );
    return '$_prefix${base64Url.encode(<int>[...box.nonce, ...box.cipherText, ...box.mac.bytes]).replaceAll('=', '')}';
  }

  Future<String?> decrypt({
    required String encryptedDisplayName,
    required String encryptedPath,
    required List<int> keyBytes,
  }) async {
    if (!encryptedDisplayName.startsWith(_prefix)) {
      return null;
    }
    try {
      final bytes = base64Url.decode(
        base64Url.normalize(encryptedDisplayName.substring(_prefix.length)),
      );
      final macLength = cipher.macAlgorithm.macLength;
      if (bytes.length <= _nonceLength + macLength) {
        return null;
      }
      final ciphertextEnd = bytes.length - macLength;
      final clearText = await cipher.decrypt(
        SecretBox(
          bytes.sublist(_nonceLength, ciphertextEnd),
          nonce: bytes.sublist(0, _nonceLength),
          mac: Mac(bytes.sublist(ciphertextEnd)),
        ),
        secretKey: SecretKey(keyBytes),
        aad: _aad(encryptedPath),
      );
      final value = utf8.decode(clearText).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  List<int> _aad(String encryptedPath) =>
      utf8.encode('vaultsync/v1/root-display-name|$encryptedPath');
}
