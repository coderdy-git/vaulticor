// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Vaulticor/main.dart';

void main() {
  testWidgets('Counter value placeholder test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const VaultApp());

    // Verify that our app starts at the login page.
    expect(find.text('Vaulticor'), findsOneWidget);
    expect(find.text('Buka Vault'), findsOneWidget);
  });
}
