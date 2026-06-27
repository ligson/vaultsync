import 'download_models.dart';

class DownloadService {
  DownloadedObject decodeLocalDownload() {
    return const DownloadedObject(
      versionId: 'ver-1',
      objectId: 'obj-1',
      syncRootId: 'root-1',
      fileName: 'hello.txt',
      bytes: [1, 2, 3],
    );
  }
}
