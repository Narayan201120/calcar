// P6 slice 3 gate: snapshot-first Riverpod state with live deltas
// after. Canned snapshot data only, no network, no real sockets: the
// socket client below uses a throwing channel factory and the binding
// is driven through handleEvent with canned SocketEvents.
//
// Failure modes covered first: pre-snapshot deltas, stale or duplicate
// seq, malformed payloads, disconnect mid-stream, expired or double
// resolve, dispose-then-event, and buffer floods past every cap.
import 'package:calcar/api/models.dart';
import 'package:calcar/realtime/realtime.dart';
import 'package:calcar/state/state.dart';
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

class FakeSnapshotSource implements SnapshotSource {
  int fetchDevicesCalls = 0;
  int fetchPresenceCalls = 0;
  int fetchComputerCalls = 0;
  int fetchWorkflowCalls = 0;

  @override
  Future<List<Device>> fetchDevices() {
    fetchDevicesCalls += 1;
    return Future<List<Device>>.value(
      <Device>[
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
      ],
    );
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    fetchPresenceCalls += 1;
    return Future<Map<String, Presence>>.value(
      <String, Presence>{
        'PH-owner': const Presence(
          deviceId: 'PH-owner',
          online: true,
          lastSeenMillis: now,
        ),
        'PC-1': const Presence(
          deviceId: 'PC-1',
          online: true,
          lastSeenMillis: now,
        ),
      },
    );
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return Future<String>.value('PH-owner');
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    fetchComputerCalls += 1;
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
          WorkflowRow(
            workflowId: 'wf-2',
            computerId: 'PC-1',
            title: 'Review PR',
            status: 'waiting_approval',
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
            id: 'a-9',
            kind: 'started',
            text: 'started',
            atMillis: now - 60000,
            seqNo: 9,
          ),
          BufferedActivity(
            id: 'a-10',
            kind: 'command_started',
            text: 'build',
            atMillis: now - 30000,
            seqNo: 10,
          ),
        ],
        chat: const <BufferedChat>[
          BufferedChat(messageId: 'm-1', body: 'hello agent', seqNo: 10),
        ],
        terminalLines: const <String>['line one', 'line two'],
        terminalTotalLines: 2,
        files: const <BufferedFile>[
          BufferedFile(path: 'a.txt', diff: '+hi'),
        ],
        approvals: const <TrackedApproval>[
          TrackedApproval(
            approvalId: 'ap-1',
            workflowId: 'wf-1',
            title: 'Run tests',
            detail: 'npm test',
            expiresAtMillis: now + 90000,
          ),
          TrackedApproval(
            approvalId: 'ap-old',
            workflowId: 'wf-1',
            title: 'Old approval',
            detail: 'too late',
            expiresAtMillis: now - 1000,
          ),
        ],
      ),
    );
  }
}

ProviderContainer _container(FakeSnapshotSource fake) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      snapshotSourceProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

CalcarSocketClient _deadSocket({required void Function() onDial}) {
  return CalcarSocketClient(
    baseUrl: 'wss://example.invalid',
    userId: 'u1',
    token: 'tok',
    channelFactory: (Uri uri, Iterable<String>? protocols) {
      onDial();
      throw StateError('no sockets in unit tests');
    },
  );
}

void main() {
  group('snapshot first, deltas after', () {
    test(
      'contract: pull refresh issues one snapshot fetch for the device list',
      () async {
        final FakeSnapshotSource fake = FakeSnapshotSource();
        final ProviderContainer container = _container(fake);
        await container.read(devicesControllerProvider.notifier).refresh();
        expect(fake.fetchDevicesCalls, 1);
        final DevicesState state = container.read(devicesControllerProvider);
        expect(
          state.devices.map((Device device) => device.deviceId),
          <String>['PH-owner', 'PH-2', 'PC-1'],
        );
        expect(state.loading, isFalse);
        expect(state.error, isEmpty);
      },
    );

    test(
      'contract: snapshot loads first and stale deltas never reorder state',
      () async {
        final ProviderContainer container = _container(FakeSnapshotSource());
        final WorkflowController controller =
            container.read(workflowControllerProvider(wfKey).notifier);
        // Deltas before the snapshot are dropped: snapshot first.
        controller.applyStatus(seqNo: 11, status: 'waiting_approval');
        expect(controller.snapshotLoaded, isFalse);
        expect(
          container.read(workflowControllerProvider(wfKey)).status,
          'running',
        );
        expect(await controller.loadSnapshot(), isTrue);
        expect(
          container.read(workflowControllerProvider(wfKey)).status,
          'running',
        );
        expect(
          container.read(workflowControllerProvider(wfKey)).lastSeqNo,
          10,
        );
        // Live deltas apply after the snapshot, in seq order.
        controller.applyStatus(seqNo: 11, status: 'waiting_approval');
        expect(
          container.read(workflowControllerProvider(wfKey)).status,
          'waiting_approval',
        );
        // Stale and duplicate seq never reorder state.
        controller.applyStatus(seqNo: 9, status: 'completed');
        controller.applyStatus(seqNo: 11, status: 'failed');
        final WorkflowBuffers state =
            container.read(workflowControllerProvider(wfKey));
        expect(state.status, 'waiting_approval');
        expect(state.lastSeqNo, 11);
      },
    );

    test(
      'contract: computer snapshot carries workflow rows, deltas apply after',
      () async {
        final FakeSnapshotSource fake = FakeSnapshotSource();
        final ProviderContainer container = _container(fake);
        final ComputerController controller = container.read(
          computerControllerProvider('PC-1').notifier,
        );
        // Header deltas before the snapshot are dropped.
        controller.applyWorkflowStatus('wf-1', 'completed');
        expect(controller.snapshotLoaded, isFalse);
        expect(await controller.refresh(), isTrue);
        expect(fake.fetchComputerCalls, 1);
        ComputerState state = container.read(
          computerControllerProvider('PC-1'),
        );
        expect(
          state.snapshot?.workflows.map(
            (WorkflowRow row) => row.workflowId,
          ),
          <String>['wf-1', 'wf-2'],
        );
        controller.applyWorkflowStatus('wf-1', 'waiting_approval');
        controller.applyPresence(online: false, lastSeenMillis: now + 1000);
        state = container.read(
          computerControllerProvider('PC-1'),
        );
        expect(state.snapshot?.workflows.first.status, 'waiting_approval');
        expect(state.snapshot?.online, isFalse);
      },
    );

    test('contract: malformed socket payloads never corrupt state', () {
      final ProviderContainer container = _container(FakeSnapshotSource());
      int calls = 0;
      final RealtimeBinding binding = RealtimeBinding(
        socket: _deadSocket(onDial: () {}),
        onPresenceChanged: ({
          required String deviceId,
          required bool online,
          required int lastSeenMillis,
        }) {
          calls += 1;
        },
      );
      addTearDown(binding.dispose);
      binding.mount();
      binding.handleEvent(
        const PresenceChanged(          msgId: 'm-bad',
          to: 'user:u1',
          payload: <String, dynamic>{'online': true},
        ),
      );
      binding.handleEvent(
        const PresenceChanged(          msgId: 'm-bad2',
          to: 'user:u1',
          payload: <String, dynamic>{
            'device_id': 'PC-1',
            'online': 'yes',
          },
        ),
      );
      binding.handleEvent(
        const AttentionPending(          msgId: 'm-bad3',
          to: 'user:u1',
          payload: <String, dynamic>{'kind': 'approval_required'},
        ),
      );
      expect(calls, 0);
      expect(container.read(devicesControllerProvider).devices, isEmpty);
    });
  });

  group('socket lifecycle', () {
    test(
      'contract: dispose closes the socket and ends the subscription',
      () async {
        int factoryCalls = 0;
        final CalcarSocketClient socket = _deadSocket(
          onDial: () => factoryCalls += 1,
        );
        final List<String> seen = <String>[];
        final RealtimeBinding binding = RealtimeBinding(
          socket: socket,
          onPresenceChanged: ({
            required String deviceId,
            required bool online,
            required int lastSeenMillis,
          }) {
            seen.add(deviceId);
          },
        );
        binding.mount();
        expect(binding.isMounted, isTrue);
        binding.handleEvent(
          const PresenceChanged(            msgId: 'm-1',
            to: 'user:u1',
            payload: <String, dynamic>{
              'device_id': 'PC-1',
              'online': true,
            },
          ),
        );
        expect(seen, <String>['PC-1']);
        binding.dispose();
        expect(binding.isMounted, isFalse);
        expect(socket.isMounted, isFalse);
        // Post-dispose events are dropped and dispose stays idempotent.
        binding.handleEvent(
          const PresenceChanged(            msgId: 'm-2',
            to: 'user:u1',
            payload: <String, dynamic>{
              'device_id': 'PC-2',
              'online': true,
            },
          ),
        );
        expect(seen, <String>['PC-1']);
        binding.dispose();
        await socket.connect();
        expect(factoryCalls, 1);
      },
    );
  });

  group('disconnect freeze', () {
    test(
      'contract: disconnect freezes state with banner flag, never completes',
      () async {
        final ProviderContainer container = _container(FakeSnapshotSource());
        final WorkflowController workflow = container.read(
          workflowControllerProvider(wfKey).notifier,
        );
        final ConnectionController connection = container.read(
          connectionControllerProvider.notifier,
        );
        expect(await workflow.loadSnapshot(), isTrue);
        // Drop: freeze inbound deltas and raise the banner.
        connection.markDisconnected();
        workflow.setFrozen(frozen: true);
        expect(
          container.read(connectionControllerProvider).showBanner,
          isTrue,
        );
        workflow.applyStatus(seqNo: 11, status: 'completed');
        // Disconnect never marks a workflow completed: a drop freezes.
        workflow.appendActivity(
          const BufferedActivity(
            id: 'a-x',
            kind: 'error',
            text: 'x',
            atMillis: now,
            seqNo: 11,
          ),
        );
        final WorkflowBuffers frozen = container.read(
          workflowControllerProvider(wfKey),
        );
        expect(frozen.status, 'running');
        expect(frozen.lastSeqNo, 10);
        expect(
          frozen.activity.map((BufferedActivity entry) => entry.id),
          <String>['a-9', 'a-10'],
        );
        // A disconnected phone sends nothing, not even resolves.
        expect(
          workflow.resolveApproval(
            'ap-1',
            approved: true,
            nowMillis: now,
          ),
          isFalse,
        );
        // Reconnect: banner clears, a snapshot refetch unfreezes.
        connection.markConnected();
        expect(
          container.read(connectionControllerProvider).showBanner,
          isFalse,
        );
        expect(await workflow.loadSnapshot(), isTrue);
        expect(workflow.frozen, isFalse);
      },
    );

    test(
      'contract: attention raises catch-up, clears after refetch',
      () {
        final ProviderContainer container = _container(FakeSnapshotSource());
        final ConnectionController connection = container.read(
          connectionControllerProvider.notifier,
        );
        connection.markConnected();
        expect(
          container.read(connectionControllerProvider).showBanner,
          isFalse,
        );
        connection.markCatchupNeeded();
        expect(
          container.read(connectionControllerProvider).needsCatchup,
          isTrue,
        );
        expect(
          container.read(connectionControllerProvider).showBanner,
          isTrue,
        );
        connection.markCaughtUp();
        expect(
          container.read(connectionControllerProvider).showBanner,
          isFalse,
        );
      },
    );
  });

  group('approval resolve', () {
    test(
      'contract: expired approval is not resendable and single resolve wins',
      () async {
        final ProviderContainer container = _container(FakeSnapshotSource());
        final WorkflowController workflow = container.read(
          workflowControllerProvider(wfKey).notifier,
        );
        expect(await workflow.loadSnapshot(), isTrue);
        // Expired approvals never resend: nothing is recorded.
        expect(
          workflow.resolveApproval(
            'ap-old',
            approved: true,
            nowMillis: now,
          ),
          isFalse,
        );
        final TrackedApproval expired = container
            .read(workflowControllerProvider(wfKey))
            .approvals
            .firstWhere(
              (TrackedApproval approval) => approval.approvalId == 'ap-old',
            );
        expect(expired.resolution, isNull);
        // Pending approvals resolve once; the second resolve loses.
        expect(
          workflow.resolveApproval(
            'ap-1',
            approved: true,
            nowMillis: now,
          ),
          isTrue,
        );
        expect(
          workflow.resolveApproval(
            'ap-1',
            approved: false,
            nowMillis: now,
          ),
          isFalse,
        );
        final TrackedApproval decided = container
            .read(workflowControllerProvider(wfKey))
            .approvals
            .firstWhere(
              (TrackedApproval approval) => approval.approvalId == 'ap-1',
            );
        expect(decided.resolution, 'approved');
        // Unknown ids resolve nothing.
        expect(
          workflow.resolveApproval(
            'ap-nope',
            approved: true,
            nowMillis: now,
          ),
          isFalse,
        );
      },
    );
  });

  group('derived badges', () {
    test(
      'contract: owner badges and online states derive from provider state',
      () async {
        final ProviderContainer container = _container(FakeSnapshotSource());
        await container.read(devicesControllerProvider.notifier).refresh();
        final DevicesState state = container.read(devicesControllerProvider);
        final Device owner = state.devices.firstWhere(
          (Device device) => device.deviceId == 'PH-owner',
        );
        final Device pc = state.devices.firstWhere(
          (Device device) => device.deviceId == 'PC-1',
        );
        expect(isOwnerDevice(owner, state.ownerDeviceId), isTrue);
        expect(isOwnerDevice(pc, state.ownerDeviceId), isFalse);
        expect(deviceStateOf(owner, state.presenceById), 'online');
        expect(deviceStateOf(pc, state.presenceById), 'online');
        expect(isRevocable(owner, state.ownerDeviceId), isFalse);
        expect(isRevocable(pc, state.ownerDeviceId), isTrue);
        container.read(devicesControllerProvider.notifier).applyPresenceChanged(
              'PC-1',
              online: false,
              lastSeenMillis: now + 1000,
            );
        final DevicesState offline = container.read(devicesControllerProvider);
        final Device pcOffline = offline.devices.firstWhere(
          (Device device) => device.deviceId == 'PC-1',
        );
        expect(deviceStateOf(pcOffline, offline.presenceById), 'offline');
        container
            .read(devicesControllerProvider.notifier)
            .applyTrustRevoked('PC-1');
        final DevicesState revoked = container.read(devicesControllerProvider);
        final Device pcRevoked = revoked.devices.firstWhere(
          (Device device) => device.deviceId == 'PC-1',
        );
        expect(deviceStateOf(pcRevoked, revoked.presenceById), 'revoked');
        expect(isRevocable(pcRevoked, revoked.ownerDeviceId), isFalse);
      },
    );
  });

  group('resource caps', () {
    test(
      'contract: buffers hold every cap under flood',
      () async {
        final ProviderContainer container = _container(FakeSnapshotSource());
        final WorkflowController workflow = container.read(
          workflowControllerProvider(wfKey).notifier,
        );
        expect(await workflow.loadSnapshot(), isTrue);
        int seq = 11;
        for (int i = 0; i < 350; i++) {
          workflow.appendChat(
            BufferedChat(messageId: 'm-f$i', body: 'hello $i', seqNo: seq),
          );
          seq += 1;
        }
        WorkflowBuffers state = container.read(
          workflowControllerProvider(wfKey),
        );
        expect(state.chat.length, kChatCap);
        expect(state.chat.last.messageId, 'm-f349');
        for (int i = 0; i < 600; i++) {
          workflow.appendActivity(
            BufferedActivity(
              id: 'e-f$i',
              kind: 'command_completed',
              text: 'done $i',
              atMillis: now + i,
              seqNo: seq,
            ),
          );
          seq += 1;
        }
        state = container.read(workflowControllerProvider(wfKey));
        expect(state.activity.length, kActivityCap);
        workflow.appendTerminal(
          seqNo: seq,
          lines: List<String>.generate(2500, (int i) => 'log line $i'),
        );
        seq += 1;
        state = container.read(workflowControllerProvider(wfKey));
        expect(state.terminalLines.length, kTerminalLineCap);
        expect(state.terminalTotalLines, 2 + 2500);
        expect(
          state.terminalTotalLines > state.terminalLines.length,
          isTrue,
        );
        workflow.appendTerminal(
          seqNo: seq,
          lines: <String>[
            String.fromCharCodes(List<int>.filled(300 * 1024, 65)),
          ],
        );
        seq += 1;
        state = container.read(workflowControllerProvider(wfKey));
        final int bytes = state.terminalLines.fold<int>(
          0,
          (int sum, String line) => sum + line.length,
        );
        expect(bytes <= kTerminalByteCap, isTrue);
        workflow.applyFiles(
          seqNo: seq,
          hunks: List<BufferedFile>.generate(
            60,
            (int i) => BufferedFile(path: 'f$i.txt', diff: '+line $i'),
          ),
        );
        state = container.read(workflowControllerProvider(wfKey));
        expect(state.files.length, kDiffFileCap);
        expect(state.filesTruncated, isTrue);
      },
    );
  });
}
