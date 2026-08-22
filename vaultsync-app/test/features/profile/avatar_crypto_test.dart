import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:vaultsync_app/features/profile/avatar_crypto.dart';
import 'package:vaultsync_app/features/sync/upload_key_store.dart';

void main() {
  test('avatar encryption round trips with upload content key', () async {
    final keys = _FakeUploadKeyStore();
    final codec = AvatarCrypto(keys);
    final source = List<int>.generate(128, (index) => index);

    final encrypted = await codec.encrypt(source);
    final decrypted = await codec.decrypt(encrypted);

    expect(encrypted, isNot(source));
    expect(decrypted, source);
  });

  test('avatar ciphertext cannot be decrypted with another key', () async {
    final source = List<int>.generate(32, (index) => index * 3);
    final encrypted = await AvatarCrypto(_FakeUploadKeyStore()).encrypt(source);

    expect(
      () => AvatarCrypto(_FakeUploadKeyStore(seed: 9)).decrypt(encrypted),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}

class _FakeUploadKeyStore implements UploadKeyStore {
  final int seed;

  _FakeUploadKeyStore({this.seed = 1});

  @override
  Future<UploadKeyMaterial> loadUploadKeys() async {
    return UploadKeyMaterial(
      contentKeyBytes: List<int>.generate(32, (index) => seed + index),
      metadataKeyBytes: List<int>.generate(32, (index) => seed + 40 + index),
    );
  }

  @override
  Future<UploadKeyMaterial> deriveAndSaveUploadKeys({
    required String email,
    required String password,
  }) {
    return loadUploadKeys();
  }
}
