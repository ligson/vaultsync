import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release Android manifest declares internet permission', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest.readAsStringSync(),
      contains('android.permission.INTERNET'),
    );
  });

  test('release Android manifest declares all files access permission', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest.readAsStringSync(),
      contains('android.permission.MANAGE_EXTERNAL_STORAGE'),
    );
  });
}
