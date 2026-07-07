import '../../core/network/api_client.dart';
import 'device_models.dart';

abstract interface class DeviceGateway {
  Future<RegisteredDevice> registerDevice({
    required String token,
    required String name,
    required String platform,
  });
}

class DeviceService implements DeviceGateway {
  final ApiClient apiClient;

  const DeviceService(this.apiClient);

  @override
  Future<RegisteredDevice> registerDevice({
    required String token,
    required String name,
    required String platform,
  }) async {
    final data = await apiClient.post(
      '/api/v1/devices',
      token: token,
      body: {'name': name, 'platform': platform},
    );
    return RegisteredDevice.fromJson(data);
  }
}
