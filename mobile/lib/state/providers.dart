// Riverpod wiring for the snapshot-first state layer.
//
// Merge step contract:
// - Override [snapshotSourceProvider] with the HTTP snapshot source and
//   [socketConfigProvider] with the authed session values.
// - My Computers watches [devicesControllerProvider] and pull-refresh
//   calls refresh (one snapshot fetch).
// - Computer detail watches computerControllerProvider(computerId) for
//   the header plus workflow rows; sysinfo stays lazy as today.
// - Workflow views watch workflowControllerProvider(key) for capped
//   buffers and connectionControllerProvider for the banner, freezing
//   via setFrozen(frozen: true) on drop and loadSnapshot on reconnect.
// - Watching [realtimeBindingProvider] keeps the foreground socket
//   mounted; popping the last viewer disposes it and closes the socket.
// - Approval sends and destructive confirm posts ride the agent channel
//   with idempotency keys; resolveApproval here is the local guard.
import 'dart:async';

import 'package:calcar/realtime/realtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'computer_controller.dart';
import 'connection_controller.dart';
import 'devices_controller.dart';
import 'models.dart';
import 'realtime_binding.dart';
import 'snapshot_source.dart';
import 'workflow_controller.dart';

/// Overridden by the merge step with the HTTP snapshot source.
final snapshotSourceProvider = Provider<SnapshotSource>(
  (Ref ref) {
    throw UnimplementedError(
      'merge step: override snapshotSourceProvider with the HTTP source',
    );
  },
);

/// Overridden by the merge step with the authed session values.
final socketConfigProvider = Provider<SocketConfig>(
  (Ref ref) {
    throw UnimplementedError(
      'merge step: override socketConfigProvider with the authed session',
    );
  },
);

final devicesControllerProvider =
    StateNotifierProvider<DevicesController, DevicesState>(
  (Ref ref) {
    return DevicesController(ref.watch(snapshotSourceProvider));
  },
);

final computerControllerProvider = StateNotifierProvider.family<
    ComputerController, ComputerState, String>(
  (Ref ref, String computerId) {
    return ComputerController(ref.watch(snapshotSourceProvider), computerId);
  },
);

final workflowControllerProvider = StateNotifierProvider.family<
    WorkflowController, WorkflowBuffers, WorkflowKey>(
  (Ref ref, WorkflowKey key) {
    return WorkflowController(
      ref.watch(snapshotSourceProvider),
      key.computerId,
      key.workflowId,
    );
  },
);

final connectionControllerProvider =
    StateNotifierProvider<ConnectionController, ConnectionState>(
  (Ref ref) {
    return ConnectionController();
  },
);

/// Foreground subscription. Auto-dispose closes the socket when the
/// last viewing widget navigates away.
final realtimeBindingProvider = Provider.autoDispose<RealtimeBinding>(
  (Ref ref) {
    final SocketConfig config = ref.watch(socketConfigProvider);
    final CalcarSocketClient socket = CalcarSocketClient(
      baseUrl: config.baseUrl,
      userId: config.userId,
      token: config.token,
      onConnectionLost: () {
        ref.read(connectionControllerProvider.notifier).markDisconnected();
      },
      onCatchupNeeded: () {
        ref.read(connectionControllerProvider.notifier).markCatchupNeeded();
      },
    );
    final RealtimeBinding binding = RealtimeBinding(
      socket: socket,
      onPresenceChanged: ({
        required String deviceId,
        required bool online,
        required int lastSeenMillis,
      }) {
        ref.read(devicesControllerProvider.notifier).applyPresenceChanged(
              deviceId,
              online: online,
              lastSeenMillis: lastSeenMillis,
            );
      },
      onAttentionPending: ({
        required String computerId,
        required String workflowId,
        required String kind,
      }) {
        ref.read(connectionControllerProvider.notifier).markCatchupNeeded();
      },
      onTrustRevoked: ({required String deviceId}) {
        ref
            .read(devicesControllerProvider.notifier)
            .applyTrustRevoked(deviceId);
      },
      onPairingChanged: () {
        unawaited(ref.read(devicesControllerProvider.notifier).refresh());
      },
      onConnectionLost: () {
        ref.read(connectionControllerProvider.notifier).markDisconnected();
      },
      onCatchupNeeded: () {
        ref.read(connectionControllerProvider.notifier).markCatchupNeeded();
      },
    );
    ref.onDispose(binding.dispose);
    binding.mount();
    return binding;
  },
);
