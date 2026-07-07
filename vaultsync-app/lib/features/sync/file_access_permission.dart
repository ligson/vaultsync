import 'package:permission_handler/permission_handler.dart';

abstract interface class FileAccessPermissionGateway {
  Future<void> openFileAccessSettings();
}

class PermissionHandlerFileAccessGateway
    implements FileAccessPermissionGateway {
  const PermissionHandlerFileAccessGateway();

  @override
  Future<void> openFileAccessSettings() async {
    await Permission.manageExternalStorage.request();
  }
}
