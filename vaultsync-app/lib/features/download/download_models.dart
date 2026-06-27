class DownloadedObject {
  final String versionId;
  final String objectId;
  final String syncRootId;
  final String fileName;
  final List<int> bytes;

  const DownloadedObject({
    required this.versionId,
    required this.objectId,
    required this.syncRootId,
    required this.fileName,
    required this.bytes,
  });
}
