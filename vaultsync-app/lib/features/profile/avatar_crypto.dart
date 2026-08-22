import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../sync/upload_key_store.dart';

class AvatarCrypto {
  static const _magic = 'VSAV001';

  final UploadKeyStore keyStore;
  final Cipher cipher;

  AvatarCrypto(this.keyStore, {Cipher? cipher})
    : cipher = cipher ?? Xchacha20.poly1305Aead();

  Future<List<int>> encrypt(List<int> bytes) async {
    final keys = await keyStore.loadUploadKeys();
    final box = await cipher.encrypt(
      bytes,
      secretKey: SecretKey(keys.contentKeyBytes),
    );
    return utf8.encode(
      jsonEncode({
        'format': _magic,
        'nonce': base64Url.encode(box.nonce),
        'ciphertext': base64Url.encode(box.cipherText),
        'mac': base64Url.encode(box.mac.bytes),
      }),
    );
  }

  Future<List<int>> decrypt(List<int> encrypted) async {
    final value = jsonDecode(utf8.decode(encrypted)) as Map;
    if (value['format'] != _magic) {
      throw const FormatException('头像密文格式不受支持');
    }
    final keys = await keyStore.loadUploadKeys();
    final box = SecretBox(
      _decode(value['ciphertext'] as String),
      nonce: _decode(value['nonce'] as String),
      mac: Mac(_decode(value['mac'] as String)),
    );
    return cipher.decrypt(box, secretKey: SecretKey(keys.contentKeyBytes));
  }

  List<int> _decode(String value) =>
      base64Url.decode(base64Url.normalize(value));
}
