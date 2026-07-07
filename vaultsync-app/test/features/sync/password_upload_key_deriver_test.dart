import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/password_upload_key_deriver.dart';
import 'package:vaultsync_app/features/sync/upload_key_store.dart';

void main() {
  const deriver = PasswordUploadKeyDeriver(memoryBlocks: 64, iterations: 1);

  test(
    'derives deterministic upload keys from normalized email and password',
    () async {
      final first = await deriver.derive(
        email: ' Alice@Example.com ',
        password: 'passw0rd!',
      );
      final second = await deriver.derive(
        email: 'alice@example.com',
        password: 'passw0rd!',
      );

      expect(first.contentKeyBytes, hasLength(uploadKeyLength));
      expect(first.metadataKeyBytes, hasLength(uploadKeyLength));
      expect(first.contentKeyBytes, second.contentKeyBytes);
      expect(first.metadataKeyBytes, second.metadataKeyBytes);
    },
  );

  test('derives different upload keys for different passwords', () async {
    final first = await deriver.derive(
      email: 'alice@example.com',
      password: 'passw0rd!',
    );
    final second = await deriver.derive(
      email: 'alice@example.com',
      password: 'another-password',
    );

    expect(first.contentKeyBytes, isNot(second.contentKeyBytes));
    expect(first.metadataKeyBytes, isNot(second.metadataKeyBytes));
  });
}
