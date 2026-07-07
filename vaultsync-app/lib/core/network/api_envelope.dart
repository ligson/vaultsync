class ApiEnvelope {
  final bool success;
  final String message;
  final int httpCode;
  final Object? data;

  const ApiEnvelope({
    required this.success,
    required this.message,
    required this.httpCode,
    required this.data,
  });

  factory ApiEnvelope.fromJson(Map<String, Object?> json) {
    return ApiEnvelope(
      success: json['success'] as bool,
      message: json['message'] as String? ?? '',
      httpCode: json['httpCode'] as int,
      data: json['data'],
    );
  }

  Map<String, Object?> dataMap() {
    final value = data;
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    return <String, Object?>{};
  }
}
