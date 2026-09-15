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
    required this.remoteBackup,
  });
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
