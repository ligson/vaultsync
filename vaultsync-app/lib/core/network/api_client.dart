class ApiClient {
  final Uri baseUrl;

  const ApiClient({required this.baseUrl});

  Uri registerPath() => baseUrl.resolve('/api/v1/auth/register');

  Uri loginPath() => baseUrl.resolve('/api/v1/auth/login');
}
