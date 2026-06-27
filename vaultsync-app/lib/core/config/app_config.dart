class AppConfig {
  final Uri apiBaseUrl;

  const AppConfig({required this.apiBaseUrl});

  factory AppConfig.fromEnvironment(Map<String, String> env) {
    final value = env['VAULTSYNC_API_BASE_URL'];
    return AppConfig(
      apiBaseUrl: Uri.parse(
        value == null || value.isEmpty ? 'http://127.0.0.1:8080' : value,
      ),
    );
  }
}
