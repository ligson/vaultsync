class AppConfig {
  final Uri apiBaseUrl;

  const AppConfig({required this.apiBaseUrl});

  factory AppConfig.fromEnvironment(
    Map<String, String> env, {
    bool isRelease = const bool.fromEnvironment('dart.vm.product'),
  }) {
    final value = env['VAULTSYNC_API_BASE_URL'];
    final defaultBaseUrl =
        isRelease ? 'https://files.ligson.xyz' : 'http://127.0.0.1:8080';
    return AppConfig(
      apiBaseUrl: Uri.parse(
        value == null || value.isEmpty ? defaultBaseUrl : value,
      ),
    );
  }
}
