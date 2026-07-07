import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_app/app.dart';

void main() {
  testWidgets('VaultSync app shows login entry', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(VaultSyncApp());
    await tester.pumpAndSettle();

    expect(find.text('VaultSync'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
