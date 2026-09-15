import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/document_center/document_center_models.dart';
import 'package:vaultsync_app/features/document_center/document_center_screen.dart';
import 'package:vaultsync_app/features/document_center/document_center_service.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  testWidgets(
    'document center loads, filters and shows details on long press',
    (tester) async {
      final entry = _entry();
      final gateway = _FakeDocumentGateway(entry);

      await tester.pumpWidget(
        MaterialApp(
          home: DocumentCenterScreen(
            documents: gateway,
            currentDeviceId: 'device-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.overviewCalls, 1);
      expect(gateway.itemCalls, 1);
      expect(find.text('项目说明.docx'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('document_type_filter')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('document_device_filter')),
        findsOneWidget,
      );

      await tester.longPress(find.byKey(const ValueKey('document_document-1')));
      await tester.pumpAndSettle();

      expect(find.text('Windows 笔记本'), findsOneWidget);
      expect(find.text('Documents/项目说明.docx'), findsOneWidget);
      expect(find.text('version-1'), findsOneWidget);
      expect(find.text('查看'), findsNothing);
    },
  );
}

class _FakeDocumentGateway implements DocumentCenterGateway {
  final DocumentCenterEntry entry;
  int overviewCalls = 0;
  int itemCalls = 0;

  _FakeDocumentGateway(this.entry);

  @override
  Future<DocumentCenterOverview> loadOverview() async {
    overviewCalls += 1;
    return const DocumentCenterOverview(
      devices: [DocumentCenterDevice(id: 'device-1', name: 'Windows 笔记本')],
    );
  }

  @override
  Future<DocumentCenterPage> loadItems({
    String documentType = '',
    String deviceId = '',
    DocumentCenterSort sort = DocumentCenterSort.time,
    DocumentCenterOrder order = DocumentCenterOrder.descending,
    int cursor = 0,
    int limit = 60,
  }) async {
    itemCalls += 1;
    if (cursor > 0) {
      return const DocumentCenterPage(items: [], nextCursor: 0, hasMore: false);
    }
    return DocumentCenterPage(items: [entry], nextCursor: 1, hasMore: false);
  }
}

DocumentCenterEntry _entry() {
  return DocumentCenterEntry(
    id: 'document-1',
    deviceId: 'device-1',
    deviceName: 'Windows 笔记本',
    syncRootId: 'root-1',
    rootName: '文档同步',
    name: '项目说明.docx',
    relativePath: 'Documents/项目说明.docx',
    documentType: 'office',
    documentFormat: 'docx',
    sizeBytes: 2048,
    updatedAt: DateTime.utc(2026, 9, 15, 10, 20),
    remoteBackup: const RemoteBackupEntry(
      syncRootId: 'root-1',
      objectId: 'object-1',
      versionId: 'version-1',
      name: '项目说明.docx',
      relativePath: 'Documents/项目说明.docx',
      sizeBytes: 2048,
      updatedAt: '2026-09-15T10:20:00Z',
      encryptedName: 'encrypted-name',
      metadataJson: '{}',
    ),
  );
}
