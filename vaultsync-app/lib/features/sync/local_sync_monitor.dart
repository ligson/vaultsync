import 'dart:async';
import 'dart:io';

import '../../core/storage/app_storage.dart';
import 'local_sync_scanner.dart';
import 'sync_models.dart';

typedef LocalSyncMonitorCallback =
    FutureOr<void> Function(Set<String> syncRootIds);

/// Watches mapped desktop folders and coalesces noisy filesystem events.
class LocalSyncMonitor {
  final SyncRootMappingStore mappings;
  final LocalSyncMonitorCallback onChanged;
  final Duration debounceDuration;
  final bool enabled;

  final Map<String, _RootWatch> _watches = {};
  final Set<String> _pendingRootIds = {};
  Timer? _debounceTimer;
  bool _started = false;
  bool _refreshing = false;
  var _suspendDepth = 0;

  LocalSyncMonitor({
    required this.mappings,
    required this.onChanged,
    this.debounceDuration = const Duration(milliseconds: 1500),
    bool? enabled,
  }) : enabled = enabled ?? _isDesktop;

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> start() async {
    if (_started || !enabled) {
      return;
    }
    _started = true;
    await refresh();
  }

  /// Refreshes watched paths after a mapping is added or removed.
  Future<void> refresh() async {
    if (!_started || _refreshing || !enabled) {
      return;
    }
    _refreshing = true;
    try {
      final configured = await mappings.loadSyncRootMappings();
      final nextById = {
        for (final mapping in configured) mapping.syncRootId: mapping,
      };

      for (final entry in _watches.entries.toList()) {
        final mapping = nextById[entry.key];
        if (mapping == null || mapping.localPath != entry.value.localPath) {
          await entry.value.dispose();
          _watches.remove(entry.key);
        }
      }

      for (final mapping in configured) {
        if (_watches.containsKey(mapping.syncRootId)) {
          continue;
        }
        final root = Directory(mapping.localPath);
        if (!await root.exists()) {
          continue;
        }
        try {
          final subscription = root
              .watch(events: FileSystemEvent.all, recursive: true)
              .listen(
                (event) => _handleEvent(mapping, event),
                onError: (Object error, StackTrace stackTrace) =>
                    _queue(mapping.syncRootId),
                cancelOnError: false,
              );
          _watches[mapping.syncRootId] = _RootWatch(
            localPath: mapping.localPath,
            subscription: subscription,
          );
        } on FileSystemException {
          // The periodic full scan remains the fallback for unsupported or
          // temporarily inaccessible filesystem watchers.
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  void _handleEvent(LocalSyncRootMapping mapping, FileSystemEvent event) {
    if (_suspendDepth > 0) {
      return;
    }
    final relativePath = _relativePath(mapping.localPath, event.path);
    if (relativePath.isNotEmpty &&
        (isIgnoredLocalSyncRelativePath(relativePath) ||
            !shouldIncludeLocalSyncFile(
              relativePath,
              sourceType: mapping.sourceType,
              includedFileTypes: mapping.includedFileTypes,
            ))) {
      return;
    }
    _queue(mapping.syncRootId);
  }

  void pause() {
    _suspendDepth += 1;
  }

  void resume() {
    if (_suspendDepth > 0) {
      _suspendDepth -= 1;
    }
  }

  void _queue(String syncRootId) {
    if (!_started) {
      return;
    }
    _pendingRootIds.add(syncRootId);
    _debounceTimer ??= Timer(debounceDuration, () {
      _debounceTimer = null;
      final ids = Set<String>.from(_pendingRootIds);
      _pendingRootIds.clear();
      if (ids.isNotEmpty && _started) {
        unawaited(Future<void>.sync(() => onChanged(ids)));
      }
    });
  }

  Future<void> stop() async {
    _started = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingRootIds.clear();
    _suspendDepth = 0;
    for (final watch in _watches.values) {
      await watch.dispose();
    }
    _watches.clear();
  }

  String _relativePath(String rootPath, String filePath) {
    final root = _normalizePath(rootPath);
    final file = _normalizePath(filePath);
    if (file == root) {
      return '';
    }
    final prefix = root.endsWith('/') ? root : '$root/';
    return file.startsWith(prefix) ? file.substring(prefix.length) : file;
  }

  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}

class _RootWatch {
  final String localPath;
  final StreamSubscription<FileSystemEvent> subscription;

  const _RootWatch({required this.localPath, required this.subscription});

  Future<void> dispose() => subscription.cancel();
}
