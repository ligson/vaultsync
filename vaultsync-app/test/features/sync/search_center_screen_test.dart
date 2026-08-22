import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/search_center_screen.dart';

SearchIndexEntry _entry({
  required String rootId,
  required String rootName,
  required String deviceId,
  required String deviceName,
  required String path,
  required String statusLabel,
  bool canPreview = true,
  bool canDownload = true,
}) {
  return SearchIndexEntry(
    rootId: rootId,
    rootName: rootName,
    deviceId: deviceId,
    deviceName: deviceName,
    isCurrentDevice: deviceId == 'device-current',
    path: path,
    sizeBytes: 2048,
    updatedAt: DateTime.utc(2026, 8, 22, 10),
    statusLabel: statusLabel,
    canPreview: canPreview,
    canDownload: canDownload,
  );
}

void main() {
  final entries = [
    _entry(
      rootId: 'root-photos',
      rootName: '照片',
      deviceId: 'device-current',
      deviceName: '当前 Mac',
      path: '2026/trip/beach.jpg',
      statusLabel: '已备份',
    ),
    _entry(
      rootId: 'root-documents',
      rootName: '文档',
      deviceId: 'device-other',
      deviceName: '办公室电脑',
      path: 'projects/plan.pdf',
      statusLabel: '仅云端',
      canPreview: false,
    ),
  ];

  Future<void> pumpSearchCenter(
    WidgetTester tester, {
    Future<void> Function(SearchIndexEntry entry)? onPreview,
    Future<void> Function(SearchIndexEntry entry)? onLocate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchCenterScreen(
          entries: entries,
          indexComplete: true,
          onPreview: onPreview,
          onLocate: onLocate,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('searches file name and path across sync roots', (tester) async {
    await pumpSearchCenter(tester);

    expect(find.text('搜索所有已加载的同步文件'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('search_center_field')),
      'beach',
    );
    await tester.pump();

    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.text('plan.pdf'), findsNothing);
    expect(find.textContaining('照片'), findsOneWidget);
    expect(find.textContaining('当前 Mac'), findsOneWidget);
  });

  testWidgets('filters by type, status, and directory', (tester) async {
    await pumpSearchCenter(tester);
    await tester.enterText(
      find.byKey(const ValueKey('search_center_field')),
      'pdf',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('search_type_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文档').last);
    await tester.pump();
    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search_status_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅云端').last);
    await tester.pump();
    expect(find.text('plan.pdf'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search_scope_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('照片').last);
    await tester.pump();
    expect(find.text('没有找到匹配文件'), findsOneWidget);
  });

  testWidgets('result actions invoke preview and locate callbacks', (
    tester,
  ) async {
    SearchIndexEntry? previewed;
    SearchIndexEntry? located;
    await pumpSearchCenter(
      tester,
      onPreview: (entry) async => previewed = entry,
      onLocate: (entry) async => located = entry,
    );
    await tester.enterText(
      find.byKey(const ValueKey('search_center_field')),
      'beach',
    );
    await tester.pump();

    await tester.tap(find.text('beach.jpg'));
    await tester.pump();
    expect(previewed?.path, '2026/trip/beach.jpg');

    await tester.tap(
      find.byKey(
        const ValueKey('search_result_actions_root-photos_2026/trip/beach.jpg'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位到同步目录'));
    await tester.pump();
    expect(located?.path, '2026/trip/beach.jpg');
  });

  testWidgets('shows incomplete index notice and requires a keyword', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchCenterScreen(entries: entries, indexComplete: false),
      ),
    );
    await tester.pump();

    expect(find.textContaining('正在后台补齐同步目录索引'), findsOneWidget);
    expect(find.text('搜索所有已加载的同步文件'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNothing);
  });
}
