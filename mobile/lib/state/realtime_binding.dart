// Foreground socket subscription for the state layer.
//
// Lifecycle: the viewing widget watches [realtimeBindingProvider], which
// mounts one binding and disposes it when the last viewer navigates
// away. Dispose cancels the event subscription and closes the socket;
// reconnect backoff runs only while mounted inside CalcarSocketClient,
// so a disposed binding can never redial.
//
// Credentials: the socket token is fixed per client, so a rotation builds
// a fresh client through [SocketFactory] and redials once. Same-token
// updates are no-ops, concurrent rotations share one flight, and a
// disposed or backgrounded binding never dials. Failures reuse the client
// backoff path, never a retry loop here.
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

  @override
  bool operator ==(Object other) {
    return other is SocketConfig &&
        other.baseUrl == baseUrl &&
        other.userId == userId &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(baseUrl, userId, token);
}

/// Builds the socket for [config]. The binding uses it for the first dial
/// and for every credential rotation, so a redial keeps the same channel
/// factory and callbacks as the mount dial.
typedef SocketFactory = CalcarSocketClient Function(SocketConfig config);

CalcarSocketClient _defaultSocket(SocketConfig config) {
  return CalcarSocketClient(
    baseUrl: config.baseUrl,
    userId: config.userId,
    token: config.token,
  );
}

class RealtimeBinding {
  RealtimeBinding({
    required CalcarSocketClient socket,
    SocketConfig? config,
    SocketFactory? socketFactory,
    this.onPresenceChanged,
    this.onAttentionPending,
    this.onTrustRevoked,
    this.onPairingChanged,
    this.onConnectionLost,
    this.onCatchupNeeded,
  })  : _socket = socket,
        _config = config ??
            SocketConfig(
              baseUrl: socket.baseUrl,
              userId: socket.userId,
              token: socket.token,
            ),
        _socketFactory = socketFactory ?? _defaultSocket;

  CalcarSocketClient _socket;
  SocketConfig _config;
  final SocketFactory _socketFactory;

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

  /// In-flight credential rotation shared by concurrent callers, so one
  /// token change costs exactly one redial instead of one per waiter.
  Future<void>? _rotation;

  bool get isMounted => _mounted && !_disposed;

  /// Credentials the live socket dialed with, or the pending ones before
  /// the first mount. Tests assert a rotation landed through this.
  SocketConfig get currentConfig => _config;

  /// Token the live socket dialed with. See [currentConfig].
  String get currentToken => _config.token;

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

  /// Redials with [nextToken], keeping the base URL and user id.
  /// Exactly one dial per distinct token: same-token calls are no-ops,
  /// concurrent calls share one flight, and a disposed or unmounted
  /// binding never dials. See [updateConfig].
  Future<void> updateToken(String nextToken) {
    return updateConfig(
      SocketConfig(
        baseUrl: _config.baseUrl,
        userId: _config.userId,
        token: nextToken,
      ),
    );
  }

  /// Redials with [next]. Same contract as [updateToken] for full
  /// credential changes. A pre-mount update swaps the pending socket
  /// without dialing, so the mount dial already carries the new creds.
  Future<void> updateConfig(SocketConfig next) {
    if (_disposed) {
      return Future<void>.value();
    }
    // Pending first: the swap inside a flight lands synchronously, so
    // an equality check here would mistake an in-flight rotation for a
    // settled one and mint a second future for the same dial.
    final Future<void>? pending = _rotation;
    if (pending != null) {
      return pending;
    }
    if (next == _config) {
      return Future<void>.value();
    }
    if (!_mounted) {
      _swap(next);
      return Future<void>.value();
    }
    final Future<void> flight = _rotate(next).whenComplete(() {
      _rotation = null;
    });
    _rotation = flight;
    return flight;
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

  /// Swaps the socket for [next] without dialing. The stale client is
  /// disposed so its backoff timer can never redial with old creds.
  CalcarSocketClient _swap(SocketConfig next) {
    unawaited(_subscription?.cancel());
    _subscription = null;
    final CalcarSocketClient stale = _socket;
    _config = next;
    final CalcarSocketClient fresh = _socketFactory(next);
    _socket = fresh;
    stale.dispose();
    return fresh;
  }

  /// Swaps the socket and dials once with the new creds. Runs
  /// synchronously until the dial, so a dispose racing the rotation
  /// either lands before the swap check and disposes the fresh client
  /// undialed, or lands after and closes it through [_socket].
  Future<void> _rotate(SocketConfig next) async {
    final CalcarSocketClient fresh = _swap(next);
    if (!_mounted || _disposed) {
      fresh.dispose();
      return;
    }
    _subscription = fresh.events.listen(handleEvent);
    await fresh.connect();
  }
}
