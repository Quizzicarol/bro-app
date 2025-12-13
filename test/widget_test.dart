// Basic Flutter widget test for Bro App
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bro_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const BroApp(isLoggedIn: false));

    // Verify that login screen loads
    expect(find.text('Login via Nostr'), findsWidgets);
  });
}