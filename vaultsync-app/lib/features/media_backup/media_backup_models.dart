class LocalMediaBackupSource {
  final String id;
  final String syncRootId;
  final String name;
  final String mediaTypes;
  final String albumScope;
  final List<String> albumIds;
  final String cleanupPolicy;
  final bool wifiOnly;
  final bool autoBackupEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LocalMediaBackupSource({
    required this.id,
    required this.syncRootId,
    required this.name,
    required this.mediaTypes,
    required this.albumScope,
    required this.albumIds,
    required this.cleanupPolicy,
    required this.wifiOnly,
    required this.autoBackupEnabled,
    required this.createdAt,
    required this.updatedAt,
  });

  factory LocalMediaBackupSource.fromJson(Map<String, Object?> json) {
    return LocalMediaBackupSource(
      id: json['id'] as String,
      syncRootId: json['sync_root_id'] as String,
      name: json['name'] as String,
      mediaTypes: json['media_types'] as String,
      albumScope: json['album_scope'] as String,
      albumIds: (json['album_ids'] as List<Object?>? ?? const [])
          .cast<String>(),
      cleanupPolicy: json['cleanup_policy'] as String,
      wifiOnly: json['wifi_only'] as bool? ?? true,
      autoBackupEnabled: json['auto_backup_enabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'sync_root_id': syncRootId,
      'name': name,
      'media_types': mediaTypes,
      'album_scope': albumScope,
      'album_ids': albumIds,
      'cleanup_policy': cleanupPolicy,
      'wifi_only': wifiOnly,
      'auto_backup_enabled': autoBackupEnabled,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

class MediaAssetSnapshot {
  final String id;
  final String albumId;
  final String albumName;
  final String mediaType;
  final String fileName;
  final String extension;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime modifiedAt;

  const MediaAssetSnapshot({
    required this.id,
    required this.albumId,
    required this.albumName,
    required this.mediaType,
    required this.fileName,
    required this.extension,
    required this.sizeBytes,
    required this.createdAt,
    required this.modifiedAt,
  });
}
