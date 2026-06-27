class SyncChangePage {
  final List<Map<String, dynamic>> items;
  final int nextCursor;
  final bool hasMore;

  const SyncChangePage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  factory SyncChangePage.fromJson(Map<String, dynamic> json) => SyncChangePage(
        items: List<Map<String, dynamic>>.from(json['items'] as List),
        nextCursor: json['next_cursor'] as int,
        hasMore: json['has_more'] as bool,
      );
}
