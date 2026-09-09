import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/sync_root_display_name_protector.dart';

void main() {
  test(
    'protects and restores a root display name with path-bound AAD',
    () async {
      final protector = SyncRootDisplayNameProtector();
      const key = <int>[
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
        31,
        32,
      ];

      final encrypted = await protector.encrypt(
        displayName: 'Downloads',
        encryptedPath: 'vaultsync-path:v1:hash',
        keyBytes: key,
      );

      expect(encrypted, startsWith('vaultsync-root-name:v1:'));
      expect(encrypted, isNot(contains('Downloads')));
      expect(
        await protector.decrypt(
          encryptedDisplayName: encrypted,
          encryptedPath: 'vaultsync-path:v1:hash',
          keyBytes: key,
        ),
        'Downloads',
      );
      expect(
        await protector.decrypt(
          encryptedDisplayName: encrypted,
          encryptedPath: 'vaultsync-path:v1:other',
          keyBytes: key,
        ),
        isNull,
      );
    },
  );
}
