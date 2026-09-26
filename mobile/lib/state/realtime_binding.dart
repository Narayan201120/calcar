// Foreground socket subscription for the state layer.
//
// Lifecycle: the viewing widget watches [realtimeBindingProvider], which
// mounts one binding and disposes it when the last viewer navigates
// away. Dispose cancels the event subscription and closes the socket;
// reconnect backoff runs only while mounted inside CalcarSocketClient,
// so a disposed binding can never redial.
//
// Routing: snapshot first, live deltas after. The binding only routes
// typed events into callbacks; the controllers enforce snapshot-before-
// delta ordering, seq high-water marks, and the disconnect freeze.
// Malformed payloads are ignored here per the additive-only rule and
// never reach the controllers.
import 'dart:async';

import 'package:calcar/realtime/realtime.dart';

/// Socket credentials for one foreground subscription. The merge step
/// overrides [socketConfigProvider] with the authed session values.
class SocketConfig {
  final String baseUrl;
  final String userId;
  final String token;

  const SocketConfig({
    required this.baseUrl,
    required this.userId,
    required this.token,
  });
}

class RealtimeBinding {
  RealtimeBinding({
    required CalcarSocketClient socket,
    this.onPresenceChanged,
    this.onAttentionPending,
    this.onTrustRevoked,
    this.onPairingChanged,
    this.onConnectionLost,
    this.onCatchupNeeded,
  }) : _socket = socket;

  final CalcarSocketClient _socket;

  final void Function({
    required String deviceId,
    required bool online,
    required int lastSeenMillis,
  })? onPresenceChanged;

  final void Function({
    required String computerId,
    required String workflowId,
    required String kind,
  })? onAttentionPending;

  final void Function({required String deviceId})? onTrustRevoked;

  final void Function()? onPairingChanged;

  final void Function()? onConnectionLost;

  final void Function()? onCatchupNeeded;

  StreamSubscription<SocketEvent>? _subscription;
  bool _mounted = false;
  bool _disposed = false;

  bool get isMounted => _mounted && !_disposed;

  /// Mounts on view: subscribes to typed events and dials the socket.
  /// Idempotent; safe to call once per viewing widget.
  void mount() {
    if (_mounted || _disposed) {
      return;
    }
    _mounted = true;
    _subscription = _socket.events.listen(handleEvent);
    unawaited(_socket.connect());
  }

  /// Routes one typed event into callbacks. Public so tests drive it
  /// with canned events and no network.
  void handleEvent(SocketEvent event) {
    if (!_mounted || _disposed) {
      return;
    }
    if (event is PresenceChanged) {
      final Object? rawId = event.payload['device_id'];
      final Object? rawOnline = event.payload['online'];
      if (rawId is String &&
          rawId.isNotEmpty &&
          rawOnline is bool) {
        onPresenceChanged?.call(
          deviceId: rawId,
          online: rawOnline,
          lastSeenMillis: DateTime.now().millisecondsSinceEpoch,
        );
      }
      return;
    }
    if (event is AttentionPending) {
      final Object? rawComputer = event.payload['computer_id'];
      final Object? rawWorkflow = event.payload['workflow_id'];
      final Object? rawKind = event.payload['kind'];
      if (rawComputer is String &&
          rawComputer.isNotEmpty &&
          rawWorkflow is String &&
          rawWorkflow.isNotEmpty &&
          rawKind is String) {
        onAttentionPending?.call(
          computerId: rawComputer,
          workflowId: rawWorkflow,
          kind: rawKind,
        );
      }
      return;
    }
    if (event is TrustRevoked) {
      final Object? rawSubject = event.payload['subject_device_id'];
      if (rawSubject is String && rawSubject.isNotEmpty) {
        onTrustRevoked?.call(deviceId: rawSubject);
      }
      return;
    }
    if (event is PairingJoinRequested || event is PairingDecided) {
      onPairingChanged?.call();
      return;
    }
    // HeartbeatEvent never reaches here; the client consumes it.
  }

  /// Socket drop path. The merge step marks the connection banner and
  /// freezes workflow controllers here, then refetches on reconnect.
  void handleDisconnect() {
    if (!_mounted || _disposed) {
      return;
    }
    onConnectionLost?.call();
  }

  /// Buffer overflow path. The UI refetches a snapshot over authed
  /// HTTP, then calls markCaughtUp on both client and connection.
  void handleCatchup() {
    if (!_mounted || _disposed) {
      return;
    }
    onCatchupNeeded?.call();
  }

  /// Disposes on navigate away: ends the subscription and closes the
  /// socket. Idempotent; pending reconnect timers become no-ops.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _mounted = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _socket.dispose();
  }
}
