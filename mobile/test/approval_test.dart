import 'package:calcar/screens/approval_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 3 gate: approval cards render a countdown, fire approve/reject
// exactly once, and go inert after expiry or resolve. Canned data only,
// no providers, no clients.

ApprovalCard _card({
  Duration remaining = const Duration(minutes: 4, seconds: 59),
  bool expired = false,
  bool resolved = false,
  String? resolution,
  VoidCallback? onApprove,
  VoidCallback? onReject,
}) {
  return ApprovalCard(
    deviceName: 'WIN-PC',
    deviceId: 'PC-1',
    fingerprint: 'A91C 7D24',
    requestTime: DateTime.utc(2026, 1, 1, 12, 0, 0),
    remaining: remaining,
    expired: expired,
    resolved: resolved,
    resolution: resolution,
    onApprove: onApprove,
    onReject: onReject,
  );
}

void main() {
  testWidgets(
    'contract: pending card shows exact join fields plus countdown',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _card())),
      );
      expect(find.text('WIN-PC'), findsOneWidget);
      expect(find.text('Device ID: PC-1'), findsOneWidget);
      expect(find.text('Fingerprint: A91C 7D24'), findsOneWidget);
      expect(find.text('Expires in 04:59'), findsOneWidget);
    },
  );

  testWidgets(
    'contract: approve fires exactly once and never fires twice',
    (tester) async {
      int approves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _card(onApprove: () => approves += 1),
          ),
        ),
      );
      await tester.tap(find.text('Approve'));
      await tester.pump();
      expect(approves, 1);
      // Parent marks the session resolved; the card must go inert.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _card(
              resolved: true,
              resolution: 'approved',
              onApprove: () => approves += 1,
            ),
          ),
        ),
      );
      expect(find.text('Resolved: approved'), findsOneWidget);
      final FilledButton button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Approve'),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.text('Approve'));
      await tester.pump();
      expect(approves, 1);
    },
  );

  testWidgets(
    'contract: reject fires exactly once and then goes inert',
    (tester) async {
      int rejects = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _card(onReject: () => rejects += 1),
          ),
        ),
      );
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(rejects, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _card(
              resolved: true,
              resolution: 'rejected',
              onReject: () => rejects += 1,
            ),
          ),
        ),
      );
      final OutlinedButton button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Reject'),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(rejects, 1);
    },
  );

  testWidgets(
    'contract: expired approval is inert and never resendable',
    (tester) async {
      int approves = 0;
      int rejects = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _card(
              expired: true,
              onApprove: () => approves += 1,
              onReject: () => rejects += 1,
            ),
          ),
        ),
      );
      expect(find.text('Expired'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Approve'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Reject'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Approve'));
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(approves, 0);
      expect(rejects, 0);
    },
  );
}
