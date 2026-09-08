import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media_backup/media_backup_gateway.dart';
import '../preview/remote_file_thumbnail.dart';
import 'media_timeline_models.dart';
import 'media_timeline_service.dart';

class MediaTimelineScreen extends StatefulWidget {
  final List<MediaTimelineEntry> entries;
  final bool indexComplete;
  final String currentDeviceId;
  final MediaTimelineGateway? timeline;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final ValueChanged<MediaTimelineEntry>? onOpen;
  final ValueChanged<MediaTimelineEntry>? onDownload;

  const MediaTimelineScreen({
    super.key,
    this.entries = const [],
    this.indexComplete = true,
    required this.currentDeviceId,
    this.timeline,
    this.mediaThumbnails,
    this.remoteFileThumbnails,
    this.onOpen,
    this.onDownload,
  });

  @override
  State<MediaTimelineScreen> createState() => _MediaTimelineScreenState();
}

class _MediaTimelineScreenState extends State<MediaTimelineScreen> {
  static const _initialMonthItemCount = 60;
  final ScrollController _scrollController = ScrollController();
  final Map<MediaTimelineMonth, GlobalKey> _monthKeys = {};
  final Map<MediaTimelineMonth, int> _visibleCounts = {};
  final Map<MediaTimelineMonth, _MonthPageState> _remotePages = {};
  List<MediaTimelineMonthSummary> _remoteMonths = const [];
  List<MediaTimelineDevice> _remoteDevices = const [];
  MediaTimelineFilter _filter = MediaTimelineFilter.all;
  String _deviceId = '';
  var _loadingOverview = false;
  var _loadGeneration = 0;
  String _loadError = '';
  var _backfillAttempted = false;

  bool get _usesRemoteIndex => widget.timeline != null;

  @override
  void initState() {
    super.initState();
    if (_usesRemoteIndex) {
      _reloadOverview();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<MediaTimelineDevice> get _devices {
    if (_usesRemoteIndex) return _remoteDevices;
    final values = <String, MediaTimelineDevice>{};
    for (final entry in widget.entries) {
      values.putIfAbsent(
        entry.deviceId,
        () => MediaTimelineDevice(id: entry.deviceId, name: entry.deviceName),
      );
    }
    final devices = values.values.toList()
      ..sort((left, right) {
        if (left.id == widget.currentDeviceId) return -1;
        if (right.id == widget.currentDeviceId) return 1;
        return left.name.compareTo(right.name);
      });
    return devices;
  }

  List<MediaTimelineEntry> get _filteredEntries {
    final result = [
      for (final entry in widget.entries)
        if ((_deviceId.isEmpty || entry.deviceId == _deviceId) &&
            (_filter == MediaTimelineFilter.all ||
                entry.mediaType == _filter.name))
          entry,
    ];
    result.sort((left, right) {
      final dateOrder = right.capturedAt.compareTo(left.capturedAt);
      return dateOrder != 0 ? dateOrder : right.id.compareTo(left.id);
    });
    return result;
  }

  Map<MediaTimelineMonth, List<MediaTimelineEntry>> get _groupedEntries {
    if (_usesRemoteIndex) {
      return {
        for (final summary in _remoteMonths)
          summary.month: _remotePages[summary.month]?.items ?? const [],
      };
    }
    final grouped = <MediaTimelineMonth, List<MediaTimelineEntry>>{};
    for (final entry in _filteredEntries) {
      final month = MediaTimelineMonth.fromDate(entry.capturedAt);
      grouped.putIfAbsent(month, () => []).add(entry);
    }
    return grouped;
  }

  String get _mediaType =>
      _filter == MediaTimelineFilter.all ? '' : _filter.name;

  Future<void> _reloadOverview() async {
    final timeline = widget.timeline;
    if (timeline == null) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loadingOverview = true;
      _loadError = '';
      _remoteMonths = const [];
      _remotePages.clear();
    });
    try {
      final overview = await timeline.loadOverview(
        mediaType: _mediaType,
        deviceId: _deviceId,
      );
      if (!mounted || generation != _loadGeneration) return;
      final shouldBackfill =
          !_backfillAttempted && timeline is MediaTimelineBackfillGateway;
      final waitingForInitialBackfill =
          overview.months.isEmpty && shouldBackfill;
      setState(() {
        _remoteMonths = overview.months;
        _remoteDevices = overview.devices;
        _loadingOverview = waitingForInitialBackfill;
      });
      if (overview.months.isNotEmpty) {
        await _loadMonth(overview.months.first.month, reset: true);
      }
      if (shouldBackfill) {
        _backfillAttempted = true;
        final indexed = await (timeline as MediaTimelineBackfillGateway)
            .backfillHistory();
        if (indexed > 0 && mounted && generation == _loadGeneration) {
          await _reloadOverview();
        } else if (waitingForInitialBackfill &&
            mounted &&
            generation == _loadGeneration) {
          setState(() => _loadingOverview = false);
        }
      }
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadingOverview = false;
        _loadError = '$error';
      });
    }
  }

  Future<void> _loadMonth(
    MediaTimelineMonth month, {
    bool reset = false,
  }) async {
    final timeline = widget.timeline;
    if (timeline == null) return;
    final current = _remotePages[month];
    if (current?.loading == true || (!reset && current?.hasMore == false)) {
      return;
    }
    final generation = _loadGeneration;
    setState(() {
      _remotePages[month] = _MonthPageState(
        items: reset ? const [] : current?.items ?? const [],
        cursor: reset ? '' : current?.cursor ?? '',
        hasMore: reset || current?.hasMore != false,
        loading: true,
      );
    });
    try {
      final page = await timeline.loadItems(
        month: month,
        mediaType: _mediaType,
        deviceId: _deviceId,
        cursor: reset ? '' : current?.cursor ?? '',
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _remotePages[month] = _MonthPageState(
          items: [
            ...(reset
                ? const <MediaTimelineEntry>[]
                : current?.items ?? const <MediaTimelineEntry>[]),
            ...page.items,
          ],
          cursor: page.nextCursor,
          hasMore: page.hasMore,
          loading: false,
        );
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _remotePages[month] = _MonthPageState(
          items: current?.items ?? const [],
          cursor: current?.cursor ?? '',
          hasMore: current?.hasMore ?? true,
          loading: false,
          error: '$error',
        );
      });
    }
  }

  Future<void> _jumpToMonth(MediaTimelineMonth month) async {
    if (_usesRemoteIndex && !_remotePages.containsKey(month)) {
      await _loadMonth(month, reset: true);
      if (!mounted) return;
    }
    final target = _monthKeys[month]?.currentContext;
    if (target != null && target.mounted) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
      return;
    }
    final months = _groupedEntries.keys.toList();
    final index = months.indexOf(month);
    if (index < 0 || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final estimatedOffset = months.length <= 1
        ? 0.0
        : position.maxScrollExtent * index / (months.length - 1);
    _scrollController
        .animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        )
        .then((_) {
          if (!mounted) return;
          final resolved = _monthKeys[month]?.currentContext;
          if (resolved == null || !resolved.mounted) return;
          Scrollable.ensureVisible(
            resolved,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            alignment: 0,
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupedEntries;
    final months = _usesRemoteIndex
        ? _remoteMonths.map((item) => item.month).toList()
        : grouped.keys.toList();
    _monthKeys.removeWhere((month, _) => !grouped.containsKey(month));

    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体'),
        actions: [
          if (_loadingOverview || (!widget.indexComplete && !_usesRemoteIndex))
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _TimelineFilters(
            filter: _filter,
            deviceId: _deviceId,
            devices: _devices,
            currentDeviceId: widget.currentDeviceId,
            onFilterChanged: (filter) {
              setState(() => _filter = filter);
              if (_usesRemoteIndex) _reloadOverview();
            },
            onDeviceChanged: (deviceId) {
              setState(() {
                _deviceId = deviceId;
                _visibleCounts.clear();
              });
              if (_usesRemoteIndex) _reloadOverview();
            },
          ),
          Expanded(
            child: _loadingOverview && months.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _loadError.isNotEmpty && months.isEmpty
                ? _TimelineLoadError(onRetry: _reloadOverview)
                : months.isEmpty
                ? const _EmptyTimeline()
                : Stack(
                    children: [
                      CustomScrollView(
                        key: const ValueKey('media_timeline_scroll'),
                        controller: _scrollController,
                        cacheExtent: 900,
                        slivers: [
                          for (final month in months) ...[
                            SliverToBoxAdapter(
                              child: _MonthHeader(
                                key: _monthKeys.putIfAbsent(
                                  month,
                                  () => GlobalKey(),
                                ),
                                month: month,
                                itemCount: _monthItemCount(month),
                              ),
                            ),
                            _monthGrid(month, grouped[month] ?? const []),
                            if (_showLoadMore(
                              month,
                              grouped[month] ?? const [],
                            ))
                              SliverToBoxAdapter(
                                child: Center(
                                  child: TextButton.icon(
                                    key: ValueKey(
                                      'load_more_media_${month.id}',
                                    ),
                                    onPressed:
                                        _remotePages[month]?.loading == true
                                        ? null
                                        : () {
                                            if (_usesRemoteIndex) {
                                              _loadMonth(
                                                month,
                                                reset: !_remotePages
                                                    .containsKey(month),
                                              );
                                            } else {
                                              setState(() {
                                                _visibleCounts[month] =
                                                    (_visibleCounts[month] ??
                                                        _initialMonthItemCount) +
                                                    _initialMonthItemCount;
                                              });
                                            }
                                          },
                                    icon: _remotePages[month]?.loading == true
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.expand_more),
                                    label: Text(
                                      _remotePages[month]?.error.isNotEmpty ==
                                              true
                                          ? '重试'
                                          : '加载更多',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                          const SliverToBoxAdapter(child: SizedBox(height: 32)),
                        ],
                      ),
                      if (months.length > 1)
                        Positioned(
                          top: 8,
                          right: 4,
                          bottom: 8,
                          child: MediaTimelineScrubber(
                            months: months,
                            onSelected: _jumpToMonth,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _monthGrid(
    MediaTimelineMonth month,
    List<MediaTimelineEntry> entries,
  ) {
    final visibleCount = _usesRemoteIndex
        ? entries.length
        : (_visibleCounts[month] ?? _initialMonthItemCount).clamp(
            0,
            entries.length,
          );
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 0, 32, 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _MediaTimelineTile(
            key: ValueKey(entries[index].id),
            entry: entries[index],
            mediaThumbnails: widget.mediaThumbnails,
            remoteFileThumbnails: widget.remoteFileThumbnails,
            timeline: widget.timeline,
            onTap: widget.onOpen == null
                ? null
                : () => widget.onOpen!(entries[index]),
            onDownload: widget.onDownload == null
                ? null
                : () => widget.onDownload!(entries[index]),
          ),
          childCount: visibleCount,
        ),
      ),
    );
  }

  int _monthItemCount(MediaTimelineMonth month) {
    if (!_usesRemoteIndex) return _groupedEntries[month]?.length ?? 0;
    for (final summary in _remoteMonths) {
      if (summary.month == month) return summary.count;
    }
    return 0;
  }

  bool _showLoadMore(
    MediaTimelineMonth month,
    List<MediaTimelineEntry> entries,
  ) {
    if (!_usesRemoteIndex) {
      return (_visibleCounts[month] ?? _initialMonthItemCount) < entries.length;
    }
    final page = _remotePages[month];
    return page == null || page.hasMore || page.error.isNotEmpty;
  }
}

class _MonthPageState {
  final List<MediaTimelineEntry> items;
  final String cursor;
  final bool hasMore;
  final bool loading;
  final String error;

  const _MonthPageState({
    required this.items,
    required this.cursor,
    required this.hasMore,
    required this.loading,
    this.error = '',
  });
}

class _TimelineFilters extends StatelessWidget {
  final MediaTimelineFilter filter;
  final String deviceId;
  final List<MediaTimelineDevice> devices;
  final String currentDeviceId;
  final ValueChanged<MediaTimelineFilter> onFilterChanged;
  final ValueChanged<String> onDeviceChanged;

  const _TimelineFilters({
    required this.filter,
    required this.deviceId,
    required this.devices,
    required this.currentDeviceId,
    required this.onFilterChanged,
    required this.onDeviceChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final typeFilter = SegmentedButton<MediaTimelineFilter>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: MediaTimelineFilter.all,
                  label: Text('全部'),
                ),
                ButtonSegment(
                  value: MediaTimelineFilter.image,
                  icon: Icon(Icons.image_outlined),
                  tooltip: '图片',
                ),
                ButtonSegment(
                  value: MediaTimelineFilter.video,
                  icon: Icon(Icons.videocam_outlined),
                  tooltip: '视频',
                ),
              ],
              selected: {filter},
              onSelectionChanged: (values) => onFilterChanged(values.first),
            );
            final deviceFilter = DropdownButton<String>(
              key: const ValueKey('media_timeline_device_filter'),
              value: deviceId,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部设备')),
                for (final device in devices)
                  DropdownMenuItem(
                    value: device.id,
                    child: Text(
                      device.id == currentDeviceId
                          ? '${device.name}（当前）'
                          : device.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => onDeviceChanged(value ?? ''),
            );
            if (constraints.maxWidth < 430) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  typeFilter,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: deviceFilter),
                ],
              );
            }
            return Row(
              children: [
                typeFilter,
                const Spacer(),
                Flexible(child: deviceFilter),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final MediaTimelineMonth month;
  final int itemCount;

  const _MonthHeader({super.key, required this.month, required this.itemCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 36, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(month.label, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${month.year} · $itemCount 项',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaTimelineTile extends StatefulWidget {
  final MediaTimelineEntry entry;
  final MediaAssetThumbnailGateway? mediaThumbnails;
  final RemoteFileThumbnailGateway? remoteFileThumbnails;
  final MediaTimelineGateway? timeline;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;

  const _MediaTimelineTile({
    super.key,
    required this.entry,
    required this.mediaThumbnails,
    required this.remoteFileThumbnails,
    required this.timeline,
    this.onTap,
    this.onDownload,
  });

  @override
  State<_MediaTimelineTile> createState() => _MediaTimelineTileState();
}

class _MediaTimelineTileState extends State<_MediaTimelineTile> {
  Future<Uint8List?>? _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _loadThumbnail();
  }

  Future<Uint8List?>? _loadThumbnail() {
    if (widget.entry.assetId.isNotEmpty && widget.mediaThumbnails != null) {
      return widget.mediaThumbnails!.loadThumbnail(widget.entry.assetId);
    }
    if (widget.timeline != null) {
      return widget.timeline!.loadThumbnail(widget.entry);
    }
    final remote = widget.entry.remoteBackup;
    if (remote != null &&
        widget.entry.mediaType == 'image' &&
        widget.remoteFileThumbnails != null) {
      return widget.remoteFileThumbnails!.load(remote);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          widget.entry.mediaType == 'video'
              ? Icons.play_circle_outline
              : Icons.image_outlined,
          size: 38,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return RepaintBoundary(
      child: Semantics(
        label: '${widget.entry.name}，来自 ${widget.entry.deviceName}',
        button: widget.onTap != null,
        child: InkWell(
          key: ValueKey('media_timeline_item_${widget.entry.id}'),
          onTap: widget.onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: _thumbnail,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null || bytes.isEmpty) return fallback;
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  );
                },
              ),
              if (widget.onDownload != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    tooltip: '下载原文件',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: widget.onDownload,
                    icon: const Icon(Icons.download_outlined, size: 18),
                  ),
                ),
              Positioned(
                left: 5,
                right: 5,
                bottom: 5,
                child: Row(
                  children: [
                    if (widget.entry.mediaType == 'video')
                      const Icon(Icons.videocam, size: 17, color: Colors.white),
                    const Spacer(),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        color: Colors.black54,
                        child: Text(
                          widget.entry.deviceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MediaTimelineScrubber extends StatefulWidget {
  final List<MediaTimelineMonth> months;
  final ValueChanged<MediaTimelineMonth> onSelected;

  const MediaTimelineScrubber({
    super.key,
    required this.months,
    required this.onSelected,
  });

  @override
  State<MediaTimelineScrubber> createState() => _MediaTimelineScrubberState();
}

class _MediaTimelineScrubberState extends State<MediaTimelineScrubber> {
  int? _activeIndex;

  void _update(Offset localPosition, double height) {
    final ratio = (localPosition.dy / height).clamp(0.0, 0.999999);
    final index = (ratio * widget.months.length).floor();
    if (_activeIndex != index) setState(() => _activeIndex = index);
  }

  void _commit() {
    final index = _activeIndex;
    if (index == null) return;
    widget.onSelected(widget.months[index]);
    setState(() => _activeIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxLabels = (constraints.maxHeight / 22).floor().clamp(2, 24);
        final step = widget.months.length <= maxLabels
            ? 1
            : (widget.months.length / maxLabels).ceil();
        final labelIndices = <int>{
          0,
          for (var index = step; index < widget.months.length; index += step)
            index,
          widget.months.length - 1,
        }.toList()..sort();
        return GestureDetector(
          key: const ValueKey('media_timeline_scrubber'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            _update(details.localPosition, constraints.maxHeight);
            _commit();
          },
          onVerticalDragStart: (details) =>
              _update(details.localPosition, constraints.maxHeight),
          onVerticalDragUpdate: (details) =>
              _update(details.localPosition, constraints.maxHeight),
          onVerticalDragEnd: (_) => _commit(),
          onVerticalDragCancel: () => setState(() => _activeIndex = null),
          child: SizedBox(
            width: 36,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerRight,
              children: [
                Container(width: 2, color: colorScheme.outlineVariant),
                for (final index in labelIndices)
                  Positioned(
                    right: 4,
                    top:
                        (constraints.maxHeight - 14) *
                        index /
                        (widget.months.length - 1),
                    child: Text(
                      widget.months[index].month == 1 || index == 0
                          ? '${widget.months[index].year}'
                          : '${widget.months[index].month}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                if (_activeIndex != null)
                  Positioned(
                    right: 28,
                    child: Material(
                      color: colorScheme.inverseSurface,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Text(
                          '${widget.months[_activeIndex!].year} 年 ${widget.months[_activeIndex!].month} 月',
                          style: TextStyle(color: colorScheme.onInverseSurface),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 42),
            SizedBox(height: 12),
            Text('暂无可展示的图片或视频'),
          ],
        ),
      ),
    );
  }
}

class _TimelineLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const _TimelineLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.icon(
        key: const ValueKey('retry_media_timeline'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('重新加载'),
      ),
    );
  }
}
