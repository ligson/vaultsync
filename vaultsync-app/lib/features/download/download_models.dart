class DownloadedObject {
  final String versionId;
  final String objectId;
  final String syncRootId;
  final String encryptedName;
  final List<int> bytes;

  const DownloadedObject({
    required this.versionId,
    required this.objectId,
    required this.syncRootId,
    required this.encryptedName,
    required this.bytes,
  });
}
