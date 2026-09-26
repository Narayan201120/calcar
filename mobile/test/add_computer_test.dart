import 'package:calcar/screens/add_computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 3 gate: Add Computer walks single-use session states and never
// reuses a session. Canned constructor data only, no providers, no clients.

AddComputerScreen _screen({
  required AddComputerStage stage,
  VoidCallback? onCreateSession,
  VoidCallback? onApprove,
  VoidCallback? onReject,
  VoidCallback? onRegenerate,
}) {
  return AddComputerScreen(
    stage: stage,
    sessionId: 's-1',
    qrNonce: 'qr-nonce-1',
    remaining: const Duration(minutes: 9, seconds: 7),
    joinDisplayName: 'WIN-PC',
    joinFingerprint: 'A91C 7D24',
    joinRequestId: 'req-1',
    onCreateSession: onCreateSession,
    onApprove: onApprove,
    onReject: onReject,
    onRegenerate: onRegenerate,
  );
}

Future<void> _pump(
  WidgetTester tester,
  AddComputerScreen screen,
) {
  return tester.pumpWidget(MaterialApp(home: screen));
}

void main() {
  testWidgets(
    'contract: create stage offers session creation',
    (tester) async {
      int creates = 0;
      await _pump(
        tester,
        _screen(
          stage: AddComputerStage.create,
          onCreateSession: () => creates += 1,
        ),
      );
      await tester.tap(find.text('Create session'));
      await tester.pump();
      expect(creates, 1);
    },
  );

  testWidgets(
    'contract: QR stage shows nonce placeholder plus countdown',
    (tester) async {
      await _pump(tester, _screen(stage: AddComputerStage.qr));
      expect(find.text('Scan this QR from your PC'), findsOneWidget);
      expect(find.byKey(const Key('qr-placeholder')), findsOneWidget);
      expect(find.text('QR: qr-nonce-1'), findsOneWidget);
      expect(find.text('Session: s-1'), findsOneWidget);
      expect(find.text('Expires in 09:07'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    },
  );

  testWidgets(
    'contract: waiting stage shows the join card with approve plus reject',
    (tester) async {
      int approves = 0;
      int rejects = 0;
      await _pump(
        tester,
        _screen(
          stage: AddComputerStage.waiting,
          onApprove: () => approves += 1,
          onReject: () => rejects += 1,
        ),
      );
      expect(find.text('Name: WIN-PC'), findsOneWidget);
      expect(find.text('Fingerprint: A91C 7D24'), findsOneWidget);
      expect(find.text('Request: req-1'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pump();
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(approves, 1);
      expect(rejects, 1);
    },
  );

  testWidgets(
    'contract: approving and rejecting stages are inert progress states',
    (tester) async {
      await _pump(tester, _screen(stage: AddComputerStage.approving));
      expect(find.text('Approving…'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      await _pump(tester, _screen(stage: AddComputerStage.rejecting));
      expect(find.text('Rejecting…'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    },
  );

  testWidgets(
    'contract: expired stage regenerates fresh and never reuses the session',
    (tester) async {
      int regenerates = 0;
      await _pump(
        tester,
        _screen(
          stage: AddComputerStage.expired,
          onRegenerate: () => regenerates += 1,
        ),
      );
      expect(find.text('Session expired'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      await tester.tap(find.text('Regenerate'));
      await tester.pump();
      expect(regenerates, 1);
    },
  );

  testWidgets(
    'contract: done stage is terminal with no reuse of the session',
    (tester) async {
      await _pump(tester, _screen(stage: AddComputerStage.done));
      expect(find.text('Session used'), findsOneWidget);
      expect(find.text('Create session'), findsNothing);
      expect(find.text('Regenerate'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    },
  );
}
