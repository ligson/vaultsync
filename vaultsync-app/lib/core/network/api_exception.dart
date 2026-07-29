import 'dart:io';

import 'package:flutter/services.dart';

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}

String readableApiMessage({
  required String code,
  required String message,
  int? statusCode,
}) {
  final trimmed = message.trim();
  final lower = trimmed.toLowerCase();
  if (trimmed.isEmpty) {
    return _fallbackMessage(code: code, statusCode: statusCode);
  }
  if (lower == 'internal server error') {
    return '服务器内部错误，请稍后重试或查看服务日志';
  }
  if (lower == 'invalid bearer token' || lower == 'missing bearer token') {
    return '登录状态已失效，请重新登录';
  }
  if (lower == 'invalid email or password') {
    return '邮箱或密码不正确';
  }
  if (lower == 'object version not found') {
    return '文件版本不存在或无权访问';
  }
  if (lower == 'sync root not found') {
    return '同步目录不存在或无权访问';
  }
  if (lower == 'sync root does not belong to user') {
    return '同步目录不存在或无权访问';
  }
  if (lower == 'sync root does not belong to device') {
    return '该同步目录不属于当前设备，请重新选择目录';
  }
  if (lower == 'device does not belong to user') {
    return '当前设备不属于该用户，请重新登录';
  }
  if (_looksLikeEnglishError(trimmed)) {
    return _fallbackMessage(code: code, statusCode: statusCode);
  }
  return trimmed;
}

String userReadableErrorMessage(Object error) {
  if (error is ApiException) {
    return readableApiMessage(
      code: error.code,
      message: error.message,
      statusCode: error.statusCode,
    );
  }
  if (error is FileSystemException) {
    return _readableFileSystemMessage(error);
  }
  if (error is PlatformException) {
    return _readablePlatformMessage(error);
  }
  final message = error.toString().replaceFirst('Exception: ', '').trim();
  if (message.isEmpty) {
    return '操作失败，请稍后重试';
  }
  if (_looksLikeEnglishError(message)) {
    return '操作失败，请稍后重试';
  }
  return message;
}

String _readableFileSystemMessage(FileSystemException error) {
  final path = error.path?.trim();
  final lower = '${error.message} ${error.osError?.message ?? ''}'
      .toLowerCase();
  if (lower.contains('permission') ||
      lower.contains('operation not permitted')) {
    return path == null || path.isEmpty
        ? '无法访问文件或目录，请确认系统权限后重试'
        : '无法访问目录 $path，请确认系统权限后重试';
  }
  if (lower.contains('no such file') || lower.contains('not found')) {
    return path == null || path.isEmpty
        ? '文件或目录不存在，请确认后重试'
        : '目录 $path 不存在，请确认后重试';
  }
  return path == null || path.isEmpty
      ? '无法读取文件或目录，请稍后重试'
      : '无法读取目录 $path，请稍后重试';
}

String _readablePlatformMessage(PlatformException error) {
  final raw = '${error.code} ${error.message ?? ''} ${error.details ?? ''}';
  final lower = raw.toLowerCase();
  if (lower.contains('permission') ||
      lower.contains('denied') ||
      lower.contains('not authorized')) {
    return '没有获得必要权限，请在系统设置中授权后重试';
  }
  if (lower.contains('not found') || lower.contains('no such')) {
    return '系统找不到要访问的文件或目录，请确认后重试';
  }
  if (lower.contains('cancel')) {
    return '操作已取消';
  }
  final message = error.message?.trim();
  if (message != null &&
      message.isNotEmpty &&
      !_looksLikeEnglishError(message)) {
    return message;
  }
  return '系统组件调用失败，请稍后重试';
}

bool _looksLikeEnglishError(String message) {
  final hasChinese = RegExp(r'[\u4e00-\u9fa5]').hasMatch(message);
  if (hasChinese) {
    return false;
  }
  return RegExp(r'[A-Za-z]').hasMatch(message);
}

String _fallbackMessage({required String code, int? statusCode}) {
  if (statusCode != null && statusCode >= 500) {
    return '服务器内部错误，请稍后重试或查看服务日志';
  }
  return switch (code) {
    'unauthorized' => '登录状态已失效，请重新登录',
    'not_found' => '资源不存在或无权访问',
    'invalid_request' => '请求参数无效，请检查后重试',
    'empty_response' => '服务器响应为空，请确认后端服务是否正常',
    'invalid_response' => '服务器返回了无法解析的响应，请确认 API 地址和后端服务状态',
    _ => '操作失败，请稍后重试',
  };
}
