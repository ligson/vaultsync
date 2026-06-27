import 'sync_models.dart';

class SyncService {
  SyncChangePage loadLocalPage() {
    return const SyncChangePage(items: [], nextCursor: 0, hasMore: false);
  }
}
