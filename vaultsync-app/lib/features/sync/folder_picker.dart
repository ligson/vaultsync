import 'package:file_selector/file_selector.dart';

abstract interface class FolderPicker {
  Future<String?> chooseSyncFolder();
}

class FileSelectorFolderPicker implements FolderPicker {
  const FileSelectorFolderPicker();

  @override
  Future<String?> chooseSyncFolder() {
    return getDirectoryPath(confirmButtonText: '选择');
  }
}
