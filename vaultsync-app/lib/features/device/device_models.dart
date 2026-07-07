class RegisteredDevice {
  final String id;
  final String userId;
  final String name;
  final String platform;
  final String createdAt;

  const RegisteredDevice({
    required this.id,
    required this.userId,
    required this.name,
    required this.platform,
    required this.createdAt,
  });

  factory RegisteredDevice.fromJson(Map<String, Object?> json) {
    return RegisteredDevice(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      platform: json['platform'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}
