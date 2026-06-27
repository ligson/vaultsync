import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/app.dart';

void main() {
  testWidgets('VaultSync app shows login entry', (WidgetTester tester) async {
    await tester.pumpWidget(const VaultSyncApp());

    expect(find.text('VaultSync'), findsOneWidget);
    expect(find.text('进入同步主页'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
