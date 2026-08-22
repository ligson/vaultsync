import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS declares the photo library usage description', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSPhotoLibraryUsageDescription</key>'));
    expect(plist, contains('用于备份用户选择的照片和视频'));
  });
}
