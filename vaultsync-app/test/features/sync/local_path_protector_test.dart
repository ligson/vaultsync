import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/local_path_protector.dart';

void main() {
  test('protectLocalPath returns stable non-plaintext path marker', () {
    const protector = Sha256LocalPathProtector();

    final protected = protector.protectLocalPath('/Users/alice/Photos');

    expect(protected, startsWith('vaultsync-path:v1:'));
    expect(protected, isNot(contains('/Users/alice/Photos')));
    expect(protected, protector.protectLocalPath('/Users/alice/Photos'));
  });
}
