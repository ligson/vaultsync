import '../sync/sync_models.dart';

enum DocumentCenterSort { time, name, type, size }

enum DocumentCenterOrder { ascending, descending }

class DocumentClassification {
  final String type;
  final String format;

  const DocumentClassification({required this.type, required this.format});
}

DocumentClassification? documentClassificationForPath(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final format = name.substring(dot + 1);
  const formats = <String, Set<String>>{
    'office': {
      'doc',
      'docx',
      'docm',
      'dot',
      'dotx',
      'dotm',
      'xls',
      'xlsx',
      'xlsm',
      'xlt',
      'xltx',
      'xltm',
      'ppt',
      'pptx',
      'pptm',
      'pot',
      'potx',
      'potm',
      'odt',
      'ods',
      'odp',
      'pages',
      'numbers',
      'key',
    },
    'pdf': {'pdf'},
    'text': {
      'txt',
      'md',
      'markdown',
      'rtf',
      'csv',
      'tsv',
      'json',
      'xml',
      'yaml',
      'yml',
      'log',
    },
    'ebook': {'epub', 'mobi', 'azw', 'azw3', 'fb2', 'djvu', 'cbz', 'cbr'},
  };
  for (final entry in formats.entries) {
    if (entry.value.contains(format)) {
      return DocumentClassification(type: entry.key, format: format);
    }
  }
  return null;
}

String documentTypeLabel(String type) => switch (type) {
  'office' => 'Office',
  'pdf' => 'PDF',
  'text' => '文本',
  'ebook' => '电子书',
  _ => '文档',
};

class DocumentCenterDevice {
  final String id;
  final String name;

  const DocumentCenterDevice({required this.id, required this.name});
}

class DocumentCenterOverview {
  final List<DocumentCenterDevice> devices;

  const DocumentCenterOverview({required this.devices});
}

class DocumentCenterEntry {
  final String id;
  final String deviceId;
  final String deviceName;
  final String syncRootId;
  final String rootName;
  final String name;
  final String relativePath;
  final String documentType;
  final String documentFormat;
  final int sizeBytes;
  final DateTime updatedAt;
  final bool encryptionEnabled;
  final RemoteBackupEntry remoteBackup;

  const DocumentCenterEntry({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.syncRootId,
    required this.rootName,
    required this.name,
    required this.relativePath,
    required this.documentType,
    required this.documentFormat,
    required this.sizeBytes,
    required this.updatedAt,
    required this.encryptionEnabled,
    required this.remoteBackup,
  });
}

class DocumentBookshelfItem {
  final String documentId;
  final String deviceId;
  final String deviceName;
  final String syncRootId;
  final String objectId;
  final String versionId;
  final String encryptedName;
  final String metadataJson;
  final String contentHash;
  final String name;
  final String relativePath;
  final String documentType;
  final String documentFormat;
  final int sizeBytes;
  final DateTime updatedAt;
  final bool encryptionEnabled;
  final String sectionId;
  final int offset;
  final double progress;
  final DateTime addedAt;
  final DateTime? lastReadAt;

  const DocumentBookshelfItem({
    required this.documentId,
    required this.deviceId,
    required this.deviceName,
    required this.syncRootId,
    required this.objectId,
    required this.versionId,
    required this.encryptedName,
    required this.metadataJson,
    required this.contentHash,
    required this.name,
    required this.relativePath,
    required this.documentType,
    required this.documentFormat,
    required this.sizeBytes,
    required this.updatedAt,
    required this.encryptionEnabled,
    required this.sectionId,
    required this.offset,
    required this.progress,
    required this.addedAt,
    required this.lastReadAt,
  });

  factory DocumentBookshelfItem.fromJson(Map<String, Object?> json) {
    return DocumentBookshelfItem(
      documentId: json['document_id'] as String,
      deviceId: json['device_id'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '未命名设备',
      syncRootId: json['sync_root_id'] as String? ?? '',
      objectId: json['object_id'] as String? ?? '',
      versionId: json['version_id'] as String? ?? '',
      encryptedName: json['encrypted_name'] as String? ?? '',
      metadataJson: json['metadata_json'] as String? ?? '',
      contentHash: json['content_hash'] as String? ?? '',
      name: json['name'] as String? ?? '未命名文档',
      relativePath: json['relative_path'] as String? ?? '',
      documentType: json['document_type'] as String? ?? 'ebook',
      documentFormat: json['document_format'] as String? ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.parse(json['updated_at'] as String),
      encryptionEnabled: json['encryption_enabled'] as bool? ?? true,
      sectionId: json['section_id'] as String? ?? '',
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      addedAt: DateTime.parse(json['added_at'] as String),
      lastReadAt: _documentOptionalDateTime(json['last_read_at']),
    );
  }
}

class DocumentPreviewSection {
  final String id;
  final String title;
  final String content;

  const DocumentPreviewSection({
    required this.id,
    required this.title,
    required this.content,
  });
}

class DocumentPreviewData {
  final String name;
  final String format;
  final String kind;
  final List<DocumentPreviewSection> sections;
  final Uri? pdfUri;
  final Map<String, String> pdfHeaders;
  final bool truncated;
  final bool paged;
  final int totalBytes;

  const DocumentPreviewData({
    required this.name,
    required this.format,
    required this.kind,
    required this.sections,
    this.pdfUri,
    this.pdfHeaders = const {},
    this.truncated = false,
    this.paged = false,
    this.totalBytes = 0,
  });
}

class DocumentPreviewChunk {
  final String sectionId;
  final int offset;
  final int nextOffset;
  final bool hasMore;
  final String content;

  const DocumentPreviewChunk({
    required this.sectionId,
    required this.offset,
    required this.nextOffset,
    required this.hasMore,
    required this.content,
  });
}

bool documentCanOnlinePreview(DocumentCenterEntry entry) {
  if (entry.encryptionEnabled) return false;
  return const {
    'pdf',
    'txt',
    'md',
    'markdown',
    'rtf',
    'csv',
    'tsv',
    'json',
    'xml',
    'yaml',
    'yml',
    'log',
    'docx',
    'docm',
    'dotx',
    'dotm',
    'xlsx',
    'xlsm',
    'xltx',
    'xltm',
    'pptx',
    'pptm',
    'potx',
    'potm',
    'odt',
    'ods',
    'odp',
    'epub',
    'mobi',
    'fb2',
  }.contains(entry.documentFormat.toLowerCase());
}

DateTime? _documentOptionalDateTime(Object? value) {
  final text = value as String?;
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}

class DocumentCenterPage {
  final List<DocumentCenterEntry> items;
  final int nextCursor;
  final bool hasMore;

  const DocumentCenterPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });
}
