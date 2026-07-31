import 'package:permission_handler/permission_handler.dart';

abstract interface class FileAccessPermissionGateway {
  Future<bool> hasFileAccessPermission();

  Future<void> openFileAccessSettings();
}

class PermissionHandlerFileAccessGateway
    implements FileAccessPermissionGateway {
  const PermissionHandlerFileAccessGateway();

  @override
  Future<bool> hasFileAccessPermission() async {
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  }

  @override
  Future<void> openFileAccessSettings() async {
    await Permission.manageExternalStorage.request();
  }
}
