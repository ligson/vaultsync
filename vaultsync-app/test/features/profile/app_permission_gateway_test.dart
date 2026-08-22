import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/profile/app_permission_gateway.dart';

void main() {
  test('permission capabilities are platform-specific', () {
    expect(PlatformAppPermissionGateway.supportsMediaFor('android'), isTrue);
    expect(PlatformAppPermissionGateway.supportsMediaFor('ios'), isTrue);
    expect(PlatformAppPermissionGateway.supportsMediaFor('macos'), isTrue);
    expect(PlatformAppPermissionGateway.supportsMediaFor('windows'), isFalse);
    expect(PlatformAppPermissionGateway.supportsMediaFor('linux'), isFalse);

    expect(PlatformAppPermissionGateway.requiresAllFilesFor('android'), isTrue);
    expect(PlatformAppPermissionGateway.requiresAllFilesFor('macos'), isFalse);
    expect(
      PlatformAppPermissionGateway.requiresAllFilesFor('windows'),
      isFalse,
    );
  });

  test('macOS opens the photo privacy settings pane', () {
    expect(
      PlatformAppPermissionGateway.systemSettingsUriFor('macos'),
      Uri.parse(
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Photos',
      ),
    );
    expect(
      PlatformAppPermissionGateway.systemSettingsUriFor('android'),
      isNull,
    );
  });
}
