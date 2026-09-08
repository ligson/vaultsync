import '../sync/sync_models.dart';

enum MediaTimelineFilter { all, image, video }

class MediaTimelineEntry {
  final String id;
  final String deviceId;
  final String deviceName;
  final String syncRootId;
  final String name;
  final String relativePath;
  final DateTime capturedAt;
  final String mediaType;
  final String assetId;
  final bool hasThumbnail;
  final RemoteBackupEntry? remoteBackup;

  const MediaTimelineEntry({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.syncRootId,
    required this.name,
    required this.relativePath,
    required this.capturedAt,
    required this.mediaType,
    this.assetId = '',
    this.hasThumbnail = false,
    this.remoteBackup,
  });
}

class MediaTimelineDevice {
  final String id;
  final String name;

  const MediaTimelineDevice({required this.id, required this.name});
}

class MediaTimelineOverview {
  final List<MediaTimelineMonthSummary> months;
  final List<MediaTimelineDevice> devices;

  const MediaTimelineOverview({required this.months, required this.devices});
}

class MediaTimelineMonthSummary {
  final MediaTimelineMonth month;
  final int count;

  const MediaTimelineMonthSummary({required this.month, required this.count});
}

class MediaTimelinePage {
  final List<MediaTimelineEntry> items;
  final String nextCursor;
  final bool hasMore;

  const MediaTimelinePage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });
}

class MediaTimelineMonth {
  final int year;
  final int month;

  const MediaTimelineMonth(this.year, this.month);

  factory MediaTimelineMonth.fromDate(DateTime date) {
    final local = date.toLocal();
    return MediaTimelineMonth(local.year, local.month);
  }

  String get id => '$year-${month.toString().padLeft(2, '0')}';

  String get label => '$month 月';

  @override
  bool operator ==(Object other) {
    return other is MediaTimelineMonth &&
        other.year == year &&
        other.month == month;
  }

  @override
  int get hashCode => Object.hash(year, month);
}
