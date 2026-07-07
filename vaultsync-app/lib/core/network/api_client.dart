import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../features/auth/auth_models.dart';
import '../storage/app_storage.dart';
import 'api_envelope.dart';
import 'api_exception.dart';

typedef AuthSessionRefresher = Future<AuthSession> Function(String token);

class ApiClient {
  final Uri baseUrl;
  final http.Client httpClient;
  final SessionStore? sessionStore;
  final AuthSessionRefresher? refreshAuthSession;

  ApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.sessionStore,
    this.refreshAuthSession,
  }) : httpClient = httpClient ?? http.Client();

  Uri registerPath() => baseUrl.resolve('/api/v1/auth/register');

  Uri loginPath() => baseUrl.resolve('/api/v1/auth/login');

  Future<void> ping() async {
    try {
      await get('/api/v1/health');
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        statusCode: 0,
        code: 'connection_failed',
        message: '无法连接后端服务，请确认 VaultSync 后端已启动，或检查后端地址是否正确',
      );
    }
  }

  Future<Map<String, Object?>> get(String path, {String? token}) async {
    return _withTokenRefresh(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.get(
            _resolve(path),
            headers: _headers(token: requestToken),
          ),
        );
        return _decodeEnvelope(response);
      },
    );
  }

  Future<Map<String, Object?>> post(
    String path, {
    required Map<String, Object?> body,
    String? token,
  }) async {
    return _withTokenRefresh(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.post(
            _resolve(path),
            headers: _headers(token: requestToken),
            body: jsonEncode(body),
          ),
        );
        return _decodeEnvelope(response);
      },
    );
  }

  Future<Map<String, Object?>> patch(
    String path, {
    required Map<String, Object?> body,
    String? token,
  }) async {
    return _withTokenRefresh(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.patch(
            _resolve(path),
            headers: _headers(token: requestToken),
            body: jsonEncode(body),
          ),
        );
        return _decodeEnvelope(response);
      },
    );
  }

  Future<Map<String, Object?>> delete(String path, {String? token}) async {
    return _withTokenRefresh(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.delete(
            _resolve(path),
            headers: _headers(token: requestToken),
          ),
        );
        return _decodeEnvelope(response);
      },
    );
  }

  Future<void> putBytes(
    String path, {
    required List<int> bytes,
    String? token,
  }) async {
    return _withTokenRefresh<void>(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.put(
            _resolve(path),
            headers: _binaryHeaders(token: requestToken),
            body: bytes,
          ),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return;
        }
        _decodeEnvelope(response);
      },
    );
  }

  Future<List<int>> getBytes(String path, {String? token}) async {
    return _withTokenRefresh(
      token: token,
      send: (requestToken) async {
        final response = await _send(
          () => httpClient.get(
            _resolve(path),
            headers: _downloadHeaders(token: requestToken),
          ),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response.bodyBytes;
        }
        _decodeEnvelope(response);
        throw StateError('unreachable');
      },
    );
  }

  Uri _resolve(String path) => baseUrl.resolve(path);

  Map<String, String> _headers({String? token}) {
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, String> _binaryHeaders({String? token}) {
    final headers = <String, String>{
      'content-type': 'application/octet-stream',
      'accept': 'application/json',
    };
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, String> _downloadHeaders({String? token}) {
    final headers = <String, String>{'accept': 'application/octet-stream'};
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        statusCode: 0,
        code: 'connection_failed',
        message: '无法连接后端服务，请确认 VaultSync 后端已启动，或检查后端地址是否正确',
      );
    }
  }

  Future<T> _withTokenRefresh<T>({
    required String? token,
    required Future<T> Function(String? token) send,
  }) async {
    try {
      return await send(token);
    } on ApiException catch (error) {
      if (!_shouldRefreshToken(error, token)) {
        rethrow;
      }
      final refreshedToken = await _refreshToken(token!);
      return send(refreshedToken);
    }
  }

  bool _shouldRefreshToken(ApiException error, String? token) {
    return error.statusCode == 401 &&
        token != null &&
        token.isNotEmpty &&
        sessionStore != null &&
        refreshAuthSession != null;
  }

  Future<String> _refreshToken(String token) async {
    try {
      final session = await refreshAuthSession!(token);
      await sessionStore!.saveAuthSession(session);
      return session.token;
    } catch (_) {
      throw const ApiException(
        statusCode: 401,
        code: 'unauthorized',
        message: '登录状态已失效，请重新登录',
      );
    }
  }

  Map<String, Object?> _decodeEnvelope(http.Response response) {
    if (response.body.trim().isEmpty) {
      throw ApiException(
        statusCode: response.statusCode,
        code: 'empty_response',
        message: '后端服务没有返回有效内容，请确认 VaultSync 后端已启动并且地址正确',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器返回了无法解析的响应，请确认 API 地址和后端服务状态',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: '服务器响应格式无效',
      );
    }
    final envelope = ApiEnvelope.fromJson(decoded);
    final data = envelope.dataMap();
    if (!envelope.success) {
      throw ApiException(
        statusCode: envelope.httpCode,
        code: data['code'] as String? ?? 'unknown_error',
        message: envelope.message,
      );
    }
    return data;
  }
}
