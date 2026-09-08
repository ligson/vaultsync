import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/media_timeline/media_timeline_models.dart';
import 'package:vaultsync_app/features/media_timeline/media_timeline_screen.dart';
import 'package:vaultsync_app/features/media_timeline/media_timeline_service.dart';

void main() {
  testWidgets('timeline groups media and filters by type and device', (
    tester,
  ) async {
    final entries = [
      _entry(
        id: 'phone-image',
        deviceId: 'phone',
        deviceName: 'Pixel',
        mediaType: 'image',
        capturedAt: DateTime(2026, 9, 8),
      ),
      _entry(
        id: 'tablet-video',
        deviceId: 'tablet',
        deviceName: 'iPad',
        mediaType: 'video',
        capturedAt: DateTime(2026, 8, 2),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MediaTimelineScreen(
          entries: entries,
          indexComplete: true,
          currentDeviceId: 'phone',
        ),
      ),
    );

    expect(find.text('9 月'), findsOneWidget);
    expect(find.text('8 月'), findsOneWidget);
    expect(find.text('Pixel'), findsOneWidget);
    expect(find.text('iPad'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    await tester.tap(find.byIcon(Icons.videocam_outlined));
    await tester.pumpAndSettle();
    expect(find.text('9 月'), findsNothing);
    expect(find.text('8 月'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('media_timeline_device_filter')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pixel（当前）').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无可展示的图片或视频'), findsOneWidget);
  });

  testWidgets('timeline exposes a monthly load point after sixty items', (
    tester,
  ) async {
    final entries = [
      for (var index = 0; index < 61; index += 1)
        _entry(
          id: 'image-$index',
          deviceId: 'phone',
          deviceName: 'Pixel',
          mediaType: 'image',
          capturedAt: DateTime(2026, 9, 8, 12, index),
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MediaTimelineScreen(
          entries: entries,
          indexComplete: true,
          currentDeviceId: 'phone',
        ),
      ),
    );

    final loadMore = find.byKey(const ValueKey('load_more_media_2026-09'));
    await tester.scrollUntilVisible(
      loadMore,
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('media_timeline_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(loadMore, findsOneWidget);
    await tester.tap(loadMore);
    await tester.pumpAndSettle();
    expect(loadMore, findsNothing);
  });

  testWidgets('timeline loads first month and uses cursor for more items', (
    tester,
  ) async {
    final gateway = _FakeTimelineGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaTimelineScreen(currentDeviceId: 'phone', timeline: gateway),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.overviewCalls, 1);
    expect(gateway.itemRequests, ['2026-09:']);
    expect(gateway.thumbnailRequests, ['first']);
    expect(find.text('9 月'), findsOneWidget);
    expect(find.text('2026 · 2 项'), findsOneWidget);

    final loadMore = find.byKey(const ValueKey('load_more_media_2026-09'));
    await tester.tap(loadMore);
    await tester.pumpAndSettle();

    expect(gateway.itemRequests, ['2026-09:', '2026-09:next-page']);
    expect(
      find.byKey(const ValueKey('media_timeline_item_second')),
      findsOneWidget,
    );
    expect(loadMore, findsNothing);
  });

  testWidgets('empty server index stays loading while history is backfilled', (
    tester,
  ) async {
    final gateway = _BackfillTimelineGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaTimelineScreen(currentDeviceId: 'phone', timeline: gateway),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(gateway.backfillCalls, 1);
    expect(find.text('暂无可展示的图片或视频'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    gateway.backfillResult.complete(1);
    await tester.pumpAndSettle();

    expect(gateway.overviewCalls, 2);
    expect(find.text('9 月'), findsOneWidget);
  });

  testWidgets('timeline controls and scrubber fit a narrow phone viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaTimelineScreen(
          currentDeviceId: 'phone',
          entries: [
            _entry(
              id: 'september-image',
              deviceId: 'phone',
              deviceName: 'Pixel 10 Pro',
              mediaType: 'image',
              capturedAt: DateTime(2026, 9, 8),
            ),
            _entry(
              id: 'august-video',
              deviceId: 'tablet',
              deviceName: 'Living Room Tablet',
              mediaType: 'video',
              capturedAt: DateTime(2026, 8, 2),
            ),
            _entry(
              id: 'july-image',
              deviceId: 'phone',
              deviceName: 'Pixel 10 Pro',
              mediaType: 'image',
              capturedAt: DateTime(2026, 7, 1),
            ),
          ],
          onDownload: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('media_timeline_scrubber')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.download_outlined), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

class _FakeTimelineGateway implements MediaTimelineGateway {
  int overviewCalls = 0;
  final List<String> itemRequests = [];
  final List<String> thumbnailRequests = [];

  @override
  Future<MediaTimelineOverview> loadOverview({
    String mediaType = '',
    String deviceId = '',
  }) async {
    overviewCalls += 1;
    return const MediaTimelineOverview(
      months: [
        MediaTimelineMonthSummary(month: MediaTimelineMonth(2026, 9), count: 2),
      ],
      devices: [MediaTimelineDevice(id: 'phone', name: 'Pixel')],
    );
  }

  @override
  Future<MediaTimelinePage> loadItems({
    required MediaTimelineMonth month,
    String mediaType = '',
    String deviceId = '',
    String cursor = '',
    int limit = 60,
  }) async {
    itemRequests.add('${month.id}:$cursor');
    return MediaTimelinePage(
      items: [
        _entry(
          id: cursor.isEmpty ? 'first' : 'second',
          deviceId: 'phone',
          deviceName: 'Pixel',
          mediaType: 'image',
          capturedAt: cursor.isEmpty
              ? DateTime.utc(2026, 9, 8)
              : DateTime.utc(2026, 9, 7),
        ),
      ],
      nextCursor: cursor.isEmpty ? 'next-page' : '',
      hasMore: cursor.isEmpty,
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(MediaTimelineEntry entry) async {
    thumbnailRequests.add(entry.id);
    return null;
  }
}

class _BackfillTimelineGateway
    implements MediaTimelineGateway, MediaTimelineBackfillGateway {
  final Completer<int> backfillResult = Completer<int>();
  int overviewCalls = 0;
  int backfillCalls = 0;

  @override
  Future<int> backfillHistory() {
    backfillCalls += 1;
    return backfillResult.future;
  }

  @override
  Future<MediaTimelineOverview> loadOverview({
    String mediaType = '',
    String deviceId = '',
  }) async {
    overviewCalls += 1;
    if (overviewCalls == 1) {
      return const MediaTimelineOverview(months: [], devices: []);
    }
    return const MediaTimelineOverview(
      months: [
        MediaTimelineMonthSummary(month: MediaTimelineMonth(2026, 9), count: 1),
      ],
      devices: [MediaTimelineDevice(id: 'phone', name: 'Pixel')],
    );
  }

  @override
  Future<MediaTimelinePage> loadItems({
    required MediaTimelineMonth month,
    String mediaType = '',
    String deviceId = '',
    String cursor = '',
    int limit = 60,
  }) async {
    return MediaTimelinePage(
      items: [
        _entry(
          id: 'backfilled',
          deviceId: 'phone',
          deviceName: 'Pixel',
          mediaType: 'image',
          capturedAt: DateTime.utc(2026, 9, 1),
        ),
      ],
      nextCursor: '',
      hasMore: false,
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(MediaTimelineEntry entry) async => null;
}

MediaTimelineEntry _entry({
  required String id,
  required String deviceId,
  required String deviceName,
  required String mediaType,
  required DateTime capturedAt,
}) {
  return MediaTimelineEntry(
    id: id,
    deviceId: deviceId,
    deviceName: deviceName,
    syncRootId: 'root-$deviceId',
    name: '$id.${mediaType == 'video' ? 'mp4' : 'jpg'}',
    relativePath: 'Camera/${capturedAt.year}/09/$id',
    capturedAt: capturedAt,
    mediaType: mediaType,
  );
}
