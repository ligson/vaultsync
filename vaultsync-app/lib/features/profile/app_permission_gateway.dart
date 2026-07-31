import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

enum AppPermissionState { granted, limited, denied, notRequired }

class AppPermissionSnapshot {
  final AppPermissionState media;
  final AppPermissionState allFiles;

  const AppPermissionSnapshot({required this.media, required this.allFiles});

  bool get isFullyGranted =>
      media == AppPermissionState.granted &&
      (allFiles == AppPermissionState.granted ||
          allFiles == AppPermissionState.notRequired);
}

abstract interface class AppPermissionGateway {
  Future<AppPermissionSnapshot> checkPermissions();

  Future<void> requestMediaPermission();

  Future<void> requestFileAccessPermission();

  Future<void> openSystemSettings();
}

class PlatformAppPermissionGateway implements AppPermissionGateway {
  final String platform;

  const PlatformAppPermissionGateway({required this.platform});

  bool get _supportsMedia =>
      platform == 'android' || platform == 'ios' || platform == 'macos';

  bool get _requiresAllFiles => platform == 'android';

  @override
  Future<AppPermissionSnapshot> checkPermissions() async {
    final media = _supportsMedia
        ? _mediaState(
            await PhotoManager.getPermissionState(
              requestOption: const PermissionRequestOption(),
            ),
          )
        : AppPermissionState.notRequired;
    final allFiles = _requiresAllFiles
        ? _fileState(await Permission.manageExternalStorage.status)
        : AppPermissionState.notRequired;
    return AppPermissionSnapshot(media: media, allFiles: allFiles);
  }

  @override
  Future<void> requestMediaPermission() async {
    if (_supportsMedia) {
      await PhotoManager.requestPermissionExtend();
    }
  }

  @override
  Future<void> requestFileAccessPermission() async {
    if (_requiresAllFiles) {
      await Permission.manageExternalStorage.request();
    }
  }

  @override
  Future<void> openSystemSettings() async {
    await openAppSettings();
  }

  AppPermissionState _mediaState(PermissionState state) {
    if (state.isAuth) {
      return AppPermissionState.granted;
    }
    if (state.isLimited) {
      return AppPermissionState.limited;
    }
    return AppPermissionState.denied;
  }

  AppPermissionState _fileState(PermissionStatus status) {
    return status.isGranted
        ? AppPermissionState.granted
        : AppPermissionState.denied;
  }
}
