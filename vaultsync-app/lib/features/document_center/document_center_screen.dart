import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../preview/remote_file_preview.dart';
import 'document_center_models.dart';
import 'document_center_service.dart';

class DocumentCenterScreen extends StatefulWidget {
  final DocumentCenterGateway documents;
  final String currentDeviceId;
  final ValueChanged<DocumentCenterEntry>? onOpen;
  final ValueChanged<DocumentCenterEntry>? onDownload;

  const DocumentCenterScreen({
    super.key,
    required this.documents,
    required this.currentDeviceId,
    this.onOpen,
    this.onDownload,
  });

  @override
  State<DocumentCenterScreen> createState() => _DocumentCenterScreenState();
}

class _DocumentCenterScreenState extends State<DocumentCenterScreen> {
  final _scrollController = ScrollController();
  List<DocumentCenterEntry> _items = const [];
  List<DocumentCenterDevice> _devices = const [];
  String _documentType = '';
  String _deviceId = '';
  DocumentCenterSort _sort = DocumentCenterSort.time;
  DocumentCenterOrder _order = DocumentCenterOrder.descending;
  int _cursor = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _loadingMore = false;
  bool _backfillAttempted = false;
  int _generation = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _reload();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || !_hasMore || _loadingMore) return;
    if (_scrollController.position.extentAfter < 480) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      _items = const [];
      _cursor = 0;
      _hasMore = true;
    });
    try {
      final overview = await widget.documents.loadOverview();
      final page = await widget.documents.loadItems(
        documentType: _documentType,
        deviceId: _deviceId,
        sort: _sort,
        order: _order,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _devices = overview.devices;
        _items = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
      final shouldBackfill =
          !_backfillAttempted &&
          widget.documents is DocumentCenterBackfillGateway;
      if (shouldBackfill) {
        _backfillAttempted = true;
        final indexed =
            await (widget.documents as DocumentCenterBackfillGateway)
                .backfillHistory();
        if (indexed > 0 && mounted && generation == _generation) {
          await _reload();
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore || _loading) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.documents.loadItems(
        documentType: _documentType,
        deviceId: _deviceId,
        sort: _sort,
        order: _order,
        cursor: _cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [..._items, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingMore = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文档')),
      body: Column(
        children: [
          _DocumentFilters(
            documentType: _documentType,
            deviceId: _deviceId,
            devices: _devices,
            currentDeviceId: widget.currentDeviceId,
            sort: _sort,
            order: _order,
            onDocumentTypeChanged: (value) {
              setState(() => _documentType = value);
              _reload();
            },
            onDeviceChanged: (value) {
              setState(() => _deviceId = value);
              _reload();
            },
            onSortChanged: (value) {
              setState(() => _sort = value);
              _reload();
            },
            onOrderChanged: () {
              setState(() {
                _order = _order == DocumentCenterOrder.ascending
                    ? DocumentCenterOrder.descending
                    : DocumentCenterOrder.ascending;
              });
              _reload();
            },
          ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _items.isEmpty) {
      return _DocumentLoadError(onRetry: _reload);
    }
    if (_items.isEmpty) {
      return const _EmptyDocuments();
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        key: const ValueKey('document_center_list'),
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: _loadingMore
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton.icon(
                        onPressed: _loadMore,
                        icon: const Icon(Icons.expand_more),
                        label: const Text('加载更多'),
                      ),
              ),
            );
          }
          final entry = _items[index];
          return _DocumentListTile(
            entry: entry,
            onTap: () => _showDetails(entry),
          );
        },
      ),
    );
  }

  Future<void> _showDetails(DocumentCenterEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DocumentDetailsDialog(
        entry: entry,
        onOpen:
            widget.onOpen == null ||
                !remoteFileCanAttemptPreview(entry.remoteBackup)
            ? null
            : () {
                Navigator.of(dialogContext).pop();
                widget.onOpen!(entry);
              },
        onDownload: widget.onDownload == null
            ? null
            : () {
                Navigator.of(dialogContext).pop();
                widget.onDownload!(entry);
              },
      ),
    );
  }
}

class _DocumentFilters extends StatelessWidget {
  final String documentType;
  final String deviceId;
  final List<DocumentCenterDevice> devices;
  final String currentDeviceId;
  final DocumentCenterSort sort;
  final DocumentCenterOrder order;
  final ValueChanged<String> onDocumentTypeChanged;
  final ValueChanged<String> onDeviceChanged;
  final ValueChanged<DocumentCenterSort> onSortChanged;
  final VoidCallback onOrderChanged;

  const _DocumentFilters({
    required this.documentType,
    required this.deviceId,
    required this.devices,
    required this.currentDeviceId,
    required this.sort,
    required this.order,
    required this.onDocumentTypeChanged,
    required this.onDeviceChanged,
    required this.onSortChanged,
    required this.onOrderChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('document_type_filter'),
                    initialValue: documentType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      prefixIcon: Icon(Icons.description_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('全部文档')),
                      DropdownMenuItem(value: 'office', child: Text('Office')),
                      DropdownMenuItem(value: 'pdf', child: Text('PDF')),
                      DropdownMenuItem(value: 'text', child: Text('文本')),
                      DropdownMenuItem(value: 'ebook', child: Text('电子书')),
                    ],
                    onChanged: (value) => onDocumentTypeChanged(value ?? ''),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('document_device_filter'),
                    initialValue: deviceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '设备',
                      prefixIcon: Icon(Icons.devices_outlined),
                      border: OutlineInputBorder(),
                    ),
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
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<DocumentCenterSort>(
                    key: const ValueKey('document_sort_filter'),
                    initialValue: sort,
                    decoration: const InputDecoration(
                      labelText: '排序',
                      prefixIcon: Icon(Icons.sort),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: DocumentCenterSort.time,
                        child: Text('更新时间'),
                      ),
                      DropdownMenuItem(
                        value: DocumentCenterSort.name,
                        child: Text('名称'),
                      ),
                      DropdownMenuItem(
                        value: DocumentCenterSort.type,
                        child: Text('类型'),
                      ),
                      DropdownMenuItem(
                        value: DocumentCenterSort.size,
                        child: Text('大小'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) onSortChanged(value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey('document_sort_order_button'),
                  tooltip: order == DocumentCenterOrder.ascending ? '升序' : '降序',
                  onPressed: onOrderChanged,
                  icon: Icon(
                    order == DocumentCenterOrder.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentListTile extends StatelessWidget {
  final DocumentCenterEntry entry;
  final VoidCallback onTap;

  const _DocumentListTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('document_${entry.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox.square(
        dimension: 40,
        child: Icon(
          _documentIcon(entry.documentType),
          color: _documentColor(entry.documentType, colorScheme),
        ),
      ),
      title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${entry.documentFormat.toUpperCase()} · ${_formatBytes(entry.sizeBytes)} · ${entry.deviceName}\n${_formatDate(entry.updatedAt)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      onLongPress: onTap,
    );
  }
}

class _DocumentDetailsDialog extends StatelessWidget {
  final DocumentCenterEntry entry;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;

  const _DocumentDetailsDialog({
    required this.entry,
    this.onOpen,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(_documentIcon(entry.documentType)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DetailRow(
                label: '类型',
                value:
                    '${documentTypeLabel(entry.documentType)} · ${entry.documentFormat.toUpperCase()}',
              ),
              _DetailRow(label: '大小', value: _formatBytes(entry.sizeBytes)),
              _DetailRow(label: '更新时间', value: _formatDate(entry.updatedAt)),
              _DetailRow(label: '设备', value: entry.deviceName),
              _DetailRow(label: '同步目录', value: entry.rootName),
              _DetailRow(label: '路径', value: entry.relativePath),
              _DetailRow(label: '对象 ID', value: entry.remoteBackup.objectId),
              _DetailRow(label: '版本 ID', value: entry.remoteBackup.versionId),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: '复制路径',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: entry.relativePath),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('路径已复制')));
                    }
                  },
                  icon: const Icon(Icons.copy_outlined),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (onDownload != null)
          TextButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_outlined),
            label: const Text('下载'),
          ),
        if (onOpen != null)
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('查看'),
          ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _DocumentLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const _DocumentLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 42),
          const SizedBox(height: 12),
          const Text('文档列表加载失败'),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _EmptyDocuments extends StatelessWidget {
  const _EmptyDocuments();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 48),
          SizedBox(height: 12),
          Text('暂无文档'),
        ],
      ),
    );
  }
}

IconData _documentIcon(String type) => switch (type) {
  'office' => Icons.article_outlined,
  'pdf' => Icons.picture_as_pdf_outlined,
  'text' => Icons.notes_outlined,
  'ebook' => Icons.menu_book_outlined,
  _ => Icons.description_outlined,
};

Color _documentColor(String type, ColorScheme colors) => switch (type) {
  'office' => colors.primary,
  'pdf' => colors.error,
  'text' => colors.tertiary,
  'ebook' => colors.secondary,
  _ => colors.onSurfaceVariant,
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
