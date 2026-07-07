import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/media_backup/media_backup_screen.dart';

void main() {
  testWidgets('media backup screen saves delete cleanup policy after confirm', (
    tester,
  ) async {
    String? cleanupPolicy;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaBackupScreen(
          onSave: (draft) async {
            cleanupPolicy = draft.cleanupPolicy;
          },
        ),
      ),
    );

    await tester.tap(find.text('上传后删除本地照片和视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已了解，继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save_media_backup_button')));
    await tester.pumpAndSettle();

    expect(cleanupPolicy, 'delete');
  });

  testWidgets(
    'media backup screen keeps local policy when delete is canceled',
    (tester) async {
      String? cleanupPolicy;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaBackupScreen(
            onSave: (draft) async {
              cleanupPolicy = draft.cleanupPolicy;
            },
          ),
        ),
      );

      await tester.tap(find.text('上传后删除本地照片和视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save_media_backup_button')));
      await tester.pumpAndSettle();

      expect(cleanupPolicy, 'keep');
    },
  );
}
