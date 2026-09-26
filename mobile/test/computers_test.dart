import 'package:calcar/screens/computers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty state points to Add Computer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ComputersScreen()));
    expect(find.text('No computers yet'), findsOneWidget);
    expect(find.text('Add Computer'), findsOneWidget);
  });
}
