import 'dart:convert';

import 'package:crypto/crypto.dart';

abstract interface class LocalPathProtector {
  String protectLocalPath(String localPath);
}

class Sha256LocalPathProtector implements LocalPathProtector {
  const Sha256LocalPathProtector();

  @override
  String protectLocalPath(String localPath) {
    final normalized = _normalize(localPath);
    final digest = sha256.convert(utf8.encode(normalized));
    final marker = base64Url.encode(digest.bytes).replaceAll('=', '');
    return 'vaultsync-path:v1:$marker';
  }

  String _normalize(String localPath) {
    var normalized = localPath.trim().replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
