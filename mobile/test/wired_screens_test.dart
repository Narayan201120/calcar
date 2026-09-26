// P6 merge gate: the wired screens connect providers to the pure screens.
// Every test drives the real widget tree through one ProviderScope with
// canned snapshots and a fake agent channel, so nothing here touches the
// network or opens a socket.
//
// Failures covered first: a list that renders nothing from its snapshot,
// a drop that keeps applying deltas, and a resolve that posts twice.
import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/api/models.dart';
import 'package:calcar/screens/wired/wired_computers.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/screens/wired/wired_workflow_view.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const int now = 1700000000000;

const WorkflowKey wfKey = WorkflowKey(
  computerId: 'PC-1',
  workflowId: 'wf-1',
);

Device _device({
  required String deviceId,
  required String role,
  required String displayName,
}) {
  return Device(
    deviceId: deviceId,
    role: role,
    displayName: displayName,
    pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    fingerprint: 'A91C 7D24',
    revoked: false,
    authorizedBy: 'PH-owner',
  );
}

class FakeSnapshotSource implements SnapshotSource {
  int fetchDevicesCalls = 0;
  int fetchWorkflowCalls = 0;

  @override
  Future<List<Device>> fetchDevices() {
    fetchDevicesCalls += 1;
    return Future<List<Device>>.value(<Device>[
      _device(
        deviceId: 'PH-owner',
        role: 'owner_phone',
        displayName: 'Owner Pixel',
      ),
      _device(deviceId: 'PC-1', role: 'computer', displayName: 'WIN-PC'),
      _device(deviceId: 'PC-2', role: 'computer', displayName: 'OFFICE-PC'),
    ]);
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    return Future<Map<String, Presence>>.value(<String, Presence>{
      'PC-1': const Presence(
        deviceId: 'PC-1',
        online: true,
        lastSeenMillis: now,
      ),
      'PC-2': const Presence(
        deviceId: 'PC-2',
        online: false,
        lastSeenMillis: now - 60000,
      ),
    });
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return Future<String>.value('PH-owner');
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    return Future<ComputerSnapshot>.value(
      ComputerSnapshot(
        deviceId: computerId,
        displayName: 'WIN-PC',
        online: true,
        lastSeenMillis: now,
        workflows: const <WorkflowRow>[
          WorkflowRow(
            workflowId: 'wf-1',
            computerId: 'PC-1',
            title: 'Build app',
            status: 'running',
          ),
        ],
      ),
    );
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    fetchWorkflowCalls += 1;
    return Future<WorkflowBuffers>.value(
      WorkflowBuffers(
        workflowId: workflowId,
        computerId: computerId,
        status: 'running',
        lastSeqNo: 10,
        activity: const <BufferedActivity>[
          BufferedActivity(
            id: 'a-10',
            kind: 'command_started',
            text: 'cargo build',
            atMillis: now,
            seqNo: 10,
          ),
        ],
        chat: const <BufferedChat>[
          BufferedChat(messageId: 'm-1', body: 'keep going', seqNo: 10),
        ],
        terminalLines: const <String>['compiling'],
        terminalTotalLines: 1,
        approvals: const <TrackedApproval>[
          TrackedApproval(
            approvalId: 'ap-1',
            workflowId: 'wf-1',
            title: 'Run migrations',
            detail: 'alembic upgrade head',
            expiresAtMillis: now + 90000,
          ),
        ],
      ),
    );
  }
}

/// Records what the wrapper sends. Overriding the send is the whole
/// point: the channel is the boundary this test owns.
class FakeAgentChannel extends AgentChannelClient {
  FakeAgentChannel()
      : super(baseUrl: 'https://agent.invalid', token: 'test-token');

  final List<Map<String, Object?>> resolves = <Map<String, Object?>>[];

  @override
  void postApprovalResolve({
    required String workflowId,
    required String requestId,
    required bool allow,
  }) {
    resolves.add(<String, Object?>{
      'workflowId': workflowId,
      'requestId': requestId,
      'allow': allow,
    });
  }
}

ProviderContainer _container(
  FakeSnapshotSource source,
  AgentChannelClient channel,
) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      snapshotSourceProvider.overrideWithValue(source),
      agentChannelProvider.overrideWithValue(channel),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );
}

void main() {
  group('wired computers list', () {
    testWidgets('contract: rows render from the device snapshot', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = _container(
        FakeSnapshotSource(),
        FakeAgentChannel(),
      );
      await _pump(tester, container, const WiredComputersScreen());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('computer-row-PC-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('computer-row-PC-2')),
        findsOneWidget,
      );
      expect(find.text('WIN-PC'), findsOneWidget);
      expect(find.text('OFFICE-PC'), findsOneWidget);
      // Presence is derived, not stored: the row shows the live state.
      expect(find.text('PC-1  online'), findsOneWidget);
      expect(find.text('PC-2  offline'), findsOneWidget);
      // A phone is not a managed computer, so it has no row here.
      expect(find.text('Owner Pixel'), findsNothing);
    });

    testWidgets(
      'contract: pull refresh issues exactly one snapshot fetch',
      (WidgetTester tester) async {
        final FakeSnapshotSource source = FakeSnapshotSource();
        final ProviderContainer container = _container(
          source,
          FakeAgentChannel(),
        );
        await _pump(tester, container, const WiredComputersScreen());
        await tester.pumpAndSettle();
        expect(source.fetchDevicesCalls, 1);

        await tester.fling(
          find.byKey(const ValueKey('computer-row-PC-1')),
          const Offset(0, 400),
          1000,
        );
        await tester.pumpAndSettle();

        expect(source.fetchDevicesCalls, 2);
      },
    );
  });

  group('wired workflow view', () {
    testWidgets(
      'contract: a drop raises the banner and stops applying deltas',
      (WidgetTester tester) async {
        final FakeSnapshotSource source = FakeSnapshotSource();
        final ProviderContainer container = _container(
          source,
          FakeAgentChannel(),
        );
        container.read(connectionControllerProvider.notifier).markConnected();
        await _pump(
          tester,
          container,
          const WiredWorkflowView(
            workflow: wfKey,
            title: 'Build app',
            nowMillis: now,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workflow-connection-banner')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('event-a-10')), findsOneWidget);

        container
            .read(connectionControllerProvider.notifier)
            .markDisconnected();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('workflow-connection-banner')),
          findsOneWidget,
        );

        // A delta that lands after the drop must be dropped, or a blink
        // would rewrite the workflow the Owner is watching.
        final WorkflowController workflow = container.read(
          workflowControllerProvider(wfKey).notifier,
        );
        workflow.applyStatus(seqNo: 11, status: 'completed');
        workflow.appendActivity(
          const BufferedActivity(
            id: 'a-11',
            kind: 'completed',
            text: 'all done',
            atMillis: now,
            seqNo: 11,
          ),
        );
        await tester.pump();
        final WorkflowBuffers frozen = container.read(
          workflowControllerProvider(wfKey),
        );
        expect(frozen.status, 'running');
        expect(frozen.lastSeqNo, 10);
        expect(find.byKey(const ValueKey('event-a-11')), findsNothing);

        // Reconnect refetches, and that refetch is what lifts the freeze.
        container.read(connectionControllerProvider.notifier).markConnected();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workflow-connection-banner')),
          findsNothing,
        );
        expect(source.fetchWorkflowCalls, 2);
        workflow.applyStatus(seqNo: 11, status: 'waiting_approval');
        await tester.pump();
        expect(
          container.read(workflowControllerProvider(wfKey)).status,
          'waiting_approval',
        );
      },
    );

    testWidgets(
      'contract: approval resolve posts once with an idempotency key then '
      'goes inert',
      (WidgetTester tester) async {
        final FakeAgentChannel channel = FakeAgentChannel();
        final ProviderContainer container = _container(
          FakeSnapshotSource(),
          channel,
        );
        container.read(connectionControllerProvider.notifier).markConnected();
        await _pump(
          tester,
          container,
          const WiredWorkflowView(
            workflow: wfKey,
            title: 'Build app',
            nowMillis: now,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('approve-ap-1')));
        await tester.pumpAndSettle();

        expect(channel.resolves.length, 1);
        expect(channel.resolves.single['workflowId'], 'wf-1');
        expect(channel.resolves.single['requestId'], 'wf-1:ap-1');
        expect(channel.resolves.single['allow'], isTrue);
        expect(find.text('Resolved: approved'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('approve-ap-1')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('reject-ap-1')),
              )
              .onPressed,
          isNull,
        );

        // A second tap on the inert card cannot post a second decision.
        await tester.tap(find.byKey(const ValueKey('approve-ap-1')));
        await tester.pumpAndSettle();
        expect(channel.resolves.length, 1);
      },
    );
  });
}
