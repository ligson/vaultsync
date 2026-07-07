class RegisteredUser {
  final String id;
  final String email;

  const RegisteredUser({required this.id, required this.email});

  factory RegisteredUser.fromJson(Map<String, Object?> json) {
    return RegisteredUser(
      id: json['id'] as String,
      email: json['email'] as String,
    );
  }
}

class AuthSession {
  final String token;
  final String tokenId;
  final String userId;
  final String expiresAt;

  const AuthSession({
    required this.token,
    required this.tokenId,
    required this.userId,
    required this.expiresAt,
  });

  factory AuthSession.fromJson(Map<String, Object?> json) {
    return AuthSession(
      token: json['token'] as String,
      tokenId: json['token_id'] as String,
      userId: json['user_id'] as String,
      expiresAt: json['expires_at'] as String,
    );
  }
}
