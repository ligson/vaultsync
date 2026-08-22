import 'dart:async';

import 'package:flutter/material.dart';

class SearchIndexEntry {
  final String rootId;
  final String rootName;
  final String deviceId;
  final String deviceName;
  final bool isCurrentDevice;
  final String path;
  final int? sizeBytes;
  final DateTime? updatedAt;
  final String statusLabel;
  final bool canPreview;
  final bool canDownload;

  const SearchIndexEntry({
    required this.rootId,
    required this.rootName,
    required this.deviceId,
    required this.deviceName,
    required this.isCurrentDevice,
    required this.path,
    required this.sizeBytes,
    required this.updatedAt,
    required this.statusLabel,
    required this.canPreview,
    required this.canDownload,
  });

  String get name {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    return separator < 0 ? normalized : normalized.substring(separator + 1);
  }

  String get type => searchFileTypeForPath(path);
}

String searchFileTypeForPath(String path) {
  final normalized = path.toLowerCase();
  final extension = normalized.contains('.')
      ? normalized.substring(normalized.lastIndexOf('.') + 1)
      : '';
  if ({
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'avif',
  }.contains(extension)) {
    return 'image';
  }
  if ({'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'}.contains(extension)) {
    return 'video';
  }
  if ({'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'}.contains(extension)) {
    return 'audio';
  }
  if ({
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'md',
  }.contains(extension)) {
    return 'document';
  }
  if ({'zip', '7z', 'rar', 'tar', 'gz', 'bz2'}.contains(extension)) {
    return 'archive';
  }
  return 'other';
}

class SearchCenterScreen extends StatefulWidget {
  final List<SearchIndexEntry> entries;
  final Future<List<SearchIndexEntry>> Function()? loadEntries;
  final bool indexComplete;
  final Future<void> Function(SearchIndexEntry entry)? onPreview;
  final Future<void> Function(SearchIndexEntry entry)? onDownload;
  final Future<void> Function(SearchIndexEntry entry)? onDetails;
  final Future<void> Function(SearchIndexEntry entry)? onLocate;

  const SearchCenterScreen({
    super.key,
    required this.entries,
    this.loadEntries,
    required this.indexComplete,
    this.onPreview,
    this.onDownload,
    this.onDetails,
    this.onLocate,
  });

  @override
  State<SearchCenterScreen> createState() => _SearchCenterScreenState();
}

class _SearchCenterScreenState extends State<SearchCenterScreen> {
  final _queryController = TextEditingController();
  late List<SearchIndexEntry> _indexedEntries;
  String _query = '';
  String _effectiveQuery = '';
  String? _rootFilter;
  String? _deviceFilter;
  String _typeFilter = 'all';
  String _statusFilter = 'all';
  var _isLoadingEntries = false;
  var _isFiltering = false;
  Timer? _queryDebounce;
  List<SearchIndexEntry>? _resultsCache;

  @override
  void initState() {
    super.initState();
    _indexedEntries = widget.entries;
    final loadEntries = widget.loadEntries;
    if (loadEntries != null) {
      _isLoadingEntries = true;
      unawaited(_loadEntries(loadEntries));
    }
  }

  Future<void> _loadEntries(
    Future<List<SearchIndexEntry>> Function() loadEntries,
  ) async {
    await Future<void>.delayed(Duration.zero);
    try {
      final entries = await loadEntries();
      if (!mounted) {
        return;
      }
      setState(() {
        _indexedEntries = entries;
        _isLoadingEntries = false;
        _resultsCache = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingEntries = false);
      }
    }
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  List<SearchIndexEntry> get _results => _resultsCache ??= _computeResults();

  List<SearchIndexEntry> _computeResults() {
    final query = _effectiveQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return const [];
    }
    final result = _indexedEntries.where((entry) {
      if (!entry.path.toLowerCase().contains(query)) {
        return false;
      }
      if (_rootFilter != null && entry.rootId != _rootFilter) {
        return false;
      }
      if (_deviceFilter != null && entry.deviceId != _deviceFilter) {
        return false;
      }
      if (_typeFilter != 'all' && entry.type != _typeFilter) {
        return false;
      }
      return _matchesStatus(entry, _statusFilter);
    }).toList();
    result.sort((left, right) {
      final nameResult = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      return nameResult == 0 ? left.path.compareTo(right.path) : nameResult;
    });
    return result;
  }

  void _onQueryChanged(String value) {
    _queryDebounce?.cancel();
    final normalized = value.trim();
    if (normalized == _effectiveQuery.trim()) {
      setState(() {
        _query = value;
        _isFiltering = false;
      });
      return;
    }
    setState(() {
      _query = value;
      _isFiltering = true;
    });
    // Coalesce changes from the same input event without delaying the visible result.
    _queryDebounce = Timer(Duration.zero, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _effectiveQuery = _query;
        _isFiltering = false;
        _resultsCache = null;
      });
    });
  }

  void _updateFilter(void Function() update) {
    setState(() {
      update();
      _resultsCache = null;
    });
  }

  bool _matchesStatus(SearchIndexEntry entry, String filter) {
    if (filter == 'all') {
      return true;
    }
    final status = entry.statusLabel;
    return switch (filter) {
      'undecryptable' => status == '无法解密',
      'failed' => status.contains('失败'),
      'pending' =>
        status.contains('待上传') ||
            status.contains('续传') ||
            status.contains('等待'),
      'cleanup' => status.contains('清理') || status.contains('删除本地'),
      'cloud' => status.contains('仅云端') || status.contains('本机未下载'),
      'backed_up' => status.contains('备份') || status.contains('同步'),
      _ => true,
    };
  }

  List<String> get _rootIds =>
      _indexedEntries.map((entry) => entry.rootId).toSet().toList();

  List<String> get _deviceIds =>
      _indexedEntries.map((entry) => entry.deviceId).toSet().toList();

  SearchIndexEntry? _entryForId(String id) {
    for (final entry in _indexedEntries) {
      if (entry.rootId == id) {
        return entry;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('搜索中心')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth > 980 ? 980.0 : double.infinity;
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: maxWidth,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  TextField(
                    key: const ValueKey('search_center_field'),
                    controller: _queryController,
                    autofocus: true,
                    onChanged: _onQueryChanged,
                    decoration: InputDecoration(
                      hintText: '搜索文件名或路径',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              onPressed: () {
                                _queryController.clear();
                                _onQueryChanged('');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SearchFilterBar(
                    rootFilter: _rootFilter,
                    deviceFilter: _deviceFilter,
                    typeFilter: _typeFilter,
                    statusFilter: _statusFilter,
                    rootIds: _rootIds,
                    deviceIds: _deviceIds,
                    entryForRoot: _entryForId,
                    entryForDevice: (id) => _indexedEntries.firstWhere(
                      (entry) => entry.deviceId == id,
                    ),
                    onRootChanged: (value) =>
                        _updateFilter(() => _rootFilter = value),
                    onDeviceChanged: (value) =>
                        _updateFilter(() => _deviceFilter = value),
                    onTypeChanged: (value) =>
                        _updateFilter(() => _typeFilter = value),
                    onStatusChanged: (value) =>
                        _updateFilter(() => _statusFilter = value),
                  ),
                  if (!widget.indexComplete) ...[
                    const SizedBox(height: 12),
                    const _SearchIndexNotice(),
                  ],
                  const SizedBox(height: 18),
                  if (_isLoadingEntries || _isFiltering)
                    const _SearchPreparingNotice()
                  else if (_query.trim().isEmpty)
                    _SearchEmptyPrompt(indexedCount: _indexedEntries.length)
                  else if (results.isEmpty)
                    const _SearchNoResults()
                  else ...[
                    Text(
                      '找到 ${results.length} 项',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    for (final entry in results)
                      _SearchResultTile(
                        key: ValueKey(
                          'search_result_${entry.rootId}_${entry.path}',
                        ),
                        entry: entry,
                        onPreview: entry.canPreview && widget.onPreview != null
                            ? () => widget.onPreview!.call(entry)
                            : null,
                        onDownload:
                            entry.canDownload && widget.onDownload != null
                            ? () => widget.onDownload!.call(entry)
                            : null,
                        onDetails: widget.onDetails == null
                            ? null
                            : () => widget.onDetails!.call(entry),
                        onLocate: widget.onLocate == null
                            ? null
                            : () => widget.onLocate!.call(entry),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SearchFilterBar extends StatelessWidget {
  final String? rootFilter;
  final String? deviceFilter;
  final String typeFilter;
  final String statusFilter;
  final List<String> rootIds;
  final List<String> deviceIds;
  final SearchIndexEntry? Function(String id) entryForRoot;
  final SearchIndexEntry Function(String id) entryForDevice;
  final ValueChanged<String?> onRootChanged;
  final ValueChanged<String?> onDeviceChanged;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onStatusChanged;

  const _SearchFilterBar({
    required this.rootFilter,
    required this.deviceFilter,
    required this.typeFilter,
    required this.statusFilter,
    required this.rootIds,
    required this.deviceIds,
    required this.entryForRoot,
    required this.entryForDevice,
    required this.onRootChanged,
    required this.onDeviceChanged,
    required this.onTypeChanged,
    required this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _SearchMenuButton<String?>(
          key: const ValueKey('search_scope_menu'),
          icon: Icons.folder_outlined,
          label: rootFilter == null
              ? '全部目录'
              : entryForRoot(rootFilter!)?.rootName ?? '指定目录',
          values: [
            const _SearchMenuValue(value: null, label: '全部目录'),
            for (final id in rootIds)
              _SearchMenuValue(
                value: id,
                label: entryForRoot(id)?.rootName ?? id,
              ),
          ],
          onSelected: onRootChanged,
        ),
        _SearchMenuButton<String?>(
          key: const ValueKey('search_device_menu'),
          icon: Icons.devices_outlined,
          label: deviceFilter == null
              ? '全部设备'
              : entryForDevice(deviceFilter!).deviceName,
          values: [
            const _SearchMenuValue(value: null, label: '全部设备'),
            for (final id in deviceIds)
              _SearchMenuValue(value: id, label: entryForDevice(id).deviceName),
          ],
          onSelected: onDeviceChanged,
        ),
        _SearchMenuButton<String>(
          key: const ValueKey('search_type_menu'),
          icon: Icons.category_outlined,
          label: _searchTypeLabel(typeFilter),
          values: [
            for (final value in const [
              'all',
              'image',
              'video',
              'audio',
              'document',
              'archive',
              'other',
            ])
              _SearchMenuValue(value: value, label: _searchTypeLabel(value)),
          ],
          onSelected: onTypeChanged,
        ),
        _SearchMenuButton<String>(
          key: const ValueKey('search_status_menu'),
          icon: Icons.sync_outlined,
          label: _searchStatusLabel(statusFilter),
          values: [
            for (final value in const [
              'all',
              'backed_up',
              'cloud',
              'pending',
              'failed',
              'cleanup',
              'undecryptable',
            ])
              _SearchMenuValue(value: value, label: _searchStatusLabel(value)),
          ],
          onSelected: onStatusChanged,
        ),
      ],
    );
  }
}

class _SearchMenuValue<T> {
  final T value;
  final String label;

  const _SearchMenuValue({required this.value, required this.label});
}

class _SearchMenuButton<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<_SearchMenuValue<T>> values;
  final ValueChanged<T> onSelected;

  const _SearchMenuButton({
    super.key,
    required this.icon,
    required this.label,
    required this.values,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: label,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in values)
          PopupMenuItem<T>(value: item.value, child: Text(item.label)),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: Icon(icon, size: 18),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final SearchIndexEntry entry;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDetails;
  final VoidCallback? onLocate;

  const _SearchResultTile({
    super.key,
    required this.entry,
    required this.onPreview,
    required this.onDownload,
    required this.onDetails,
    required this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final metadata = [
      entry.rootName,
      entry.deviceName,
      if (entry.sizeBytes != null) _formatSearchBytes(entry.sizeBytes!),
      if (entry.updatedAt != null) _formatSearchDate(entry.updatedAt!),
      entry.statusLabel,
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Icon(_searchFileIcon(entry.type), color: colorScheme.primary),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            metadata.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      isThreeLine: true,
      onTap: onPreview ?? onDetails,
      trailing: PopupMenuButton<_SearchAction>(
        key: ValueKey('search_result_actions_${entry.rootId}_${entry.path}'),
        tooltip: '搜索结果操作',
        onSelected: (action) {
          switch (action) {
            case _SearchAction.preview:
              onPreview?.call();
            case _SearchAction.download:
              onDownload?.call();
            case _SearchAction.details:
              onDetails?.call();
            case _SearchAction.locate:
              onLocate?.call();
          }
        },
        itemBuilder: (context) => [
          if (onPreview != null)
            const PopupMenuItem(
              value: _SearchAction.preview,
              child: Text('在线预览'),
            ),
          if (onDownload != null)
            const PopupMenuItem(
              value: _SearchAction.download,
              child: Text('下载到本地'),
            ),
          if (onDetails != null)
            const PopupMenuItem(
              value: _SearchAction.details,
              child: Text('文件详情'),
            ),
          if (onLocate != null)
            const PopupMenuItem(
              value: _SearchAction.locate,
              child: Text('定位到同步目录'),
            ),
        ],
      ),
    );
  }
}

enum _SearchAction { preview, download, details, locate }

class _SearchIndexNotice extends StatelessWidget {
  const _SearchIndexNotice();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '正在后台补齐同步目录索引，当前结果来自已加载的文件元数据。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _SearchPreparingNotice extends StatelessWidget {
  const _SearchPreparingNotice();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(height: 12),
          Text('正在准备本机搜索索引'),
        ],
      ),
    );
  }
}

class _SearchEmptyPrompt extends StatelessWidget {
  final int indexedCount;

  const _SearchEmptyPrompt({required this.indexedCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          const Icon(Icons.manage_search_outlined, size: 42),
          const SizedBox(height: 12),
          const Text('搜索所有已加载的同步文件'),
          const SizedBox(height: 6),
          Text(
            '当前索引 $indexedCount 个文件。搜索关键词不会上传服务器。',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SearchNoResults extends StatelessWidget {
  const _SearchNoResults();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          Icon(Icons.search_off_outlined, size: 42),
          SizedBox(height: 12),
          Text('没有找到匹配文件'),
          SizedBox(height: 6),
          Text('可以尝试搜索文件名、扩展名或相对路径。'),
        ],
      ),
    );
  }
}

IconData _searchFileIcon(String type) {
  return switch (type) {
    'image' => Icons.image_outlined,
    'video' => Icons.movie_outlined,
    'audio' => Icons.audiotrack_outlined,
    'document' => Icons.description_outlined,
    'archive' => Icons.archive_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

String _searchTypeLabel(String type) {
  return switch (type) {
    'image' => '图片',
    'video' => '视频',
    'audio' => '音频',
    'document' => '文档',
    'archive' => '压缩包',
    'other' => '其他',
    _ => '全部类型',
  };
}

String _searchStatusLabel(String status) {
  return switch (status) {
    'backed_up' => '已备份',
    'cloud' => '仅云端',
    'pending' => '待上传',
    'failed' => '上传失败',
    'cleanup' => '待清理',
    'undecryptable' => '无法解密',
    _ => '全部状态',
  };
}

String _formatSearchBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatSearchDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
