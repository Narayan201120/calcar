// Empty My Computers refresh: a stale empty list is escapable without
// a restart. Every test drives the real widget tree with a canned empty
// snapshot source, so nothing here touches the network.
import 'package:calcar/api/models.dart';
import 'package:calcar/screens/computers.dart';
import 'package:calcar/screens/wired/wired_computers.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Empty device list with a refresh counter. Presence and Owner id are
/// canned; computer and workflow fetches never run from this list.
class EmptySnapshotSource implements SnapshotSource {
  int fetchDevicesCalls = 0;

  @override
  Future<List<Device>> fetchDevices() {
    fetchDevicesCalls += 1;
    return Future<List<Device>>.value(<Device>[]);
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    return Future<Map<String, Presence>>.value(<String, Presence>{});
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return Future<String>.value('');
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    throw UnimplementedError('the empty list never fetches a computer');
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    throw UnimplementedError('the empty list never fetches a workflow');
  }
}

/// Failing device list with a refresh counter. Every refresh rejects,
/// so the error frame stays up and retry stays observable.
class FailingSnapshotSource extends EmptySnapshotSource {
  @override
  Future<List<Device>> fetchDevices() {
    fetchDevicesCalls += 1;
    return Future<List<Device>>.error(StateError('network down'));
  }
}

Future<void> _pumpComputers(
  WidgetTester tester,
  EmptySnapshotSource source,
) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      snapshotSourceProvider.overrideWithValue(source),
    ],
  );
  addTearDown(container.dispose);
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: WiredComputersScreen()),
    ),
  );
}

void main() {
  group('empty computers refresh', () {
    testWidgets(
      'contract: the empty list shows a refresh button that issues exactly '
      'one snapshot fetch',
      (WidgetTester tester) async {
        final EmptySnapshotSource source = EmptySnapshotSource();
        await _pumpComputers(tester, source);
        await tester.pumpAndSettle();
        expect(find.text('No computers yet'), findsOneWidget);
        expect(source.fetchDevicesCalls, 1);

        await tester.tap(find.byKey(const ValueKey('computers-refresh')));
        await tester.pumpAndSettle();

        expect(source.fetchDevicesCalls, 2);
      },
    );

    testWidgets(
      'contract: empty list pull refresh issues exactly one snapshot fetch',
      (WidgetTester tester) async {
        final EmptySnapshotSource source = EmptySnapshotSource();
        await _pumpComputers(tester, source);
        await tester.pumpAndSettle();
        expect(source.fetchDevicesCalls, 1);

        await tester.fling(
          find.byType(SingleChildScrollView),
          const Offset(0, 400),
          1000,
        );
        await tester.pumpAndSettle();

        expect(source.fetchDevicesCalls, 2);
      },
    );

    testWidgets(
      'contract: the pure empty screen calls onRefresh once per gesture',
      (WidgetTester tester) async {
        int refreshes = 0;
        Future<void> onRefresh() async {
          refreshes += 1;
        }

        await tester.pumpWidget(
          MaterialApp(home: ComputersScreen(onRefresh: onRefresh)),
        );
        await tester.pumpAndSettle();
        expect(find.text('No computers yet'), findsOneWidget);

        await tester.fling(
          find.byType(SingleChildScrollView),
          const Offset(0, 400),
          1000,
        );
        await tester.pumpAndSettle();
        expect(refreshes, 1);

        await tester.tap(find.byKey(const ValueKey('computers-refresh')));
        await tester.pumpAndSettle();
        expect(refreshes, 2);
      },
    );

    testWidgets(
      'contract: a failed load offers retry that issues exactly one '
      'snapshot fetch',
      (WidgetTester tester) async {
        final FailingSnapshotSource source = FailingSnapshotSource();
        await _pumpComputers(tester, source);
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not load computers'), findsOneWidget);
        expect(source.fetchDevicesCalls, 1);

        await tester.tap(find.byKey(const ValueKey('computers-retry')));
        await tester.pumpAndSettle();

        expect(source.fetchDevicesCalls, 2);
        expect(find.textContaining('Could not load computers'), findsOneWidget);
      },
    );
  });
}
