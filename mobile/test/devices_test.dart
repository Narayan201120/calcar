import 'dart:async';

import 'package:calcar/api/models.dart';
import 'package:calcar/screens/devices.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 3 gate: device management groups phones plus computers, badges
// the Owner, and rolls back optimistic revoke removals on failure.
// Canned devices plus presence only, no providers, no clients.

Device _device({
  required String deviceId,
  required String role,
  required String displayName,
  bool revoked = false,
}) {
  return Device(
    deviceId: deviceId,
    role: role,
    displayName: displayName,
    pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    fingerprint: 'A91C 7D24',
    revoked: revoked,
    authorizedBy: 'PH-owner',
  );
}

List<Device> _canned() {
  return <Device>[
    _device(
      deviceId: 'PH-owner',
      role: 'owner_phone',
      displayName: 'Owner Pixel',
    ),
    _device(
      deviceId: 'PH-2',
      role: 'trusted_phone',
      displayName: 'Spare Phone',
    ),
    _device(
      deviceId: 'PC-1',
      role: 'computer',
      displayName: 'WIN-PC',
    ),
  ];
}

Map<String, Presence> _presence() {
  return <String, Presence>{
    'PH-owner': const Presence(
      deviceId: 'PH-owner',
      online: true,
      lastSeenMillis: 1760000000000,
    ),
    'PH-2': const Presence(
      deviceId: 'PH-2',
      online: false,
      lastSeenMillis: 1759990000000,
    ),
    'PC-1': const Presence(
      deviceId: 'PC-1',
      online: true,
      lastSeenMillis: 1760000001000,
    ),
  };
}

Future<void> _pump(
  WidgetTester tester, {
  Future<bool> Function(Device device)? onRevoke,
  ValueChanged<Device>? onRollback,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: DevicesScreen(
        devices: _canned(),
        presenceById: _presence(),
        ownerDeviceId: 'PH-owner',
        onRevoke: onRevoke ?? (_) async => true,
        onRollback: onRollback,
      ),
    ),
  );
}

void main() {
  testWidgets(
    'contract: Owner badge is shown on the owner phone only',
    (tester) async {
      await _pump(tester);
      expect(
        find.byKey(const Key('owner-badge-PH-owner')),
        findsOneWidget,
      );
      expect(find.text('Owner'), findsOneWidget);
      expect(
        find.byKey(const Key('owner-badge-PH-2')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('owner-badge-PC-1')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'contract: phones and computers group under their section headers',
    (tester) async {
      await _pump(tester);
      expect(find.text('Trusted phones'), findsOneWidget);
      expect(find.text('Managed computers'), findsOneWidget);
      expect(find.text('Owner Pixel'), findsOneWidget);
      expect(find.text('Spare Phone'), findsOneWidget);
      expect(find.text('WIN-PC'), findsOneWidget);
      expect(find.textContaining('Type: owner_phone'), findsOneWidget);
      expect(find.textContaining('Type: computer'), findsOneWidget);
      expect(find.textContaining('ID: PC-1'), findsOneWidget);
      expect(find.textContaining('State: online'), findsNWidgets(2));
      expect(find.textContaining('State: offline'), findsOneWidget);
      final String pcSeen = DateTime.fromMillisecondsSinceEpoch(
        1760000001000,
        isUtc: true,
      ).toIso8601String();
      expect(find.textContaining('Last seen: $pcSeen'), findsOneWidget);
    },
  );

  testWidgets(
    'contract: owner has no revoke button but other devices do',
    (tester) async {
      await _pump(tester);
      expect(
        find.byKey(const Key('revoke-PH-owner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('revoke-PC-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('revoke-PH-2')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'contract: revoke success keeps the optimistic removal',
    (tester) async {
      Device? revoked;
      await _pump(
        tester,
        onRevoke: (Device device) async {
          revoked = device;
          return true;
        },
      );
      await tester.tap(find.byKey(const Key('revoke-PC-1')));
      await tester.pump();
      await tester.pump();
      expect(find.text('WIN-PC'), findsNothing);
      expect(revoked?.deviceId, 'PC-1');
    },
  );

  testWidgets(
    'contract: revoke failure rolls the row back and notifies onRollback',
    (tester) async {
      final Completer<bool> gate = Completer<bool>();
      Device? rolledBack;
      await _pump(
        tester,
        onRevoke: (_) => gate.future,
        onRollback: (Device device) => rolledBack = device,
      );
      await tester.tap(find.byKey(const Key('revoke-PC-1')));
      await tester.pump();
      // Optimistic removal hides the row while the revoke is in flight.
      expect(find.text('WIN-PC'), findsNothing);
      gate.complete(false);
      await tester.pump();
      await tester.pump();
      expect(find.text('WIN-PC'), findsOneWidget);
      expect(rolledBack?.deviceId, 'PC-1');
    },
  );

  testWidgets(
    'contract: revoke throw rolls the row back and notifies onRollback',
    (tester) async {
      Device? rolledBack;
      await _pump(
        tester,
        onRevoke: (_) async {
          throw StateError('fresh re-auth lapsed');
        },
        onRollback: (Device device) => rolledBack = device,
      );
      await tester.tap(find.byKey(const Key('revoke-PH-2')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Spare Phone'), findsOneWidget);
      expect(rolledBack?.deviceId, 'PH-2');
    },
  );
}
