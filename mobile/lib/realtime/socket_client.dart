import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'heartbeat_tracker.dart';
import 'inbound_buffer.dart';
import 'reconnect_policy.dart';
import 'socket_event.dart';

// Foreground-only realtime socket client for the P3 signal plane.
//
// Lifecycle: the viewing widget creates one client, calls [connect],
// and must call [dispose] on navigate away. Dispose closes the socket,
// cancels heartbeat and reconnect timers, and latches [_mounted] false
// so no backoff timer can ever dial again. Reconnect backoff runs only
// while mounted. There is no background handling here; background is
// push only per PLAN.md P6.
//
// Wire: token rides `?access_token=` (backend also accepts Bearer and
// subprotocol, but query is the most reliable from Flutter). After
// connect the client auto-subscribes to `user:<userId>`; cross-user
// topics are never requested. Heartbeats go out every
// [heartbeatInterval] (default 30s, matching the hub); three
// consecutive silent intervals drop the socket for a backoff reconnect.
// A full [InboundBuffer] drops new events and latches needsCatchup so
// the UI refetches a snapshot over authenticated HTTP.
//
// Dispose semantics (also pinned by socket_test.dart): dispose is
// idempotent, closes the sink and channel, cancels all timers, closes
// the event stream, and any pending reconnect timer becomes a no-op.

/// Builds a channel for [uri] with the given subprotocols.
typedef SocketChannelFactory = WebSocketChannel Function(
  Uri uri,
  Iterable<String>? protocols,
);

/// Foreground WebSocket client. See file docs for the lifecycle contract.
class CalcarSocketClient {
  /// Base http(s)/ws(s) origin, e.g. `wss://pc.tailnet:8443`.
  final String baseUrl;

  /// Authenticated user id. Used only for the `user:<id>` subscribe topic.
  final String userId;

  /// Access token sent as `?access_token=`.
  final String token;

  /// Heartbeat send plus silence-check interval. Defaults to 30s.
  final Duration heartbeatInterval;

  /// Called the first time the inbound buffer overflows.
  final void Function()? onCatchupNeeded;

  /// Called when the socket drops and backoff starts.
  final void Function()? onConnectionLost;

  final SocketChannelFactory _channelFactory;
  final HeartbeatTracker _heartbeats = HeartbeatTracker();
  final InboundBuffer<SocketEvent> _buffer;
  final ReconnectPolicy _reconnects = ReconnectPolicy();
  final StreamController<SocketEvent> _events =
      StreamController<SocketEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _mounted = true;
  bool _disposed = false;
  bool _notifiedCatchup = false;

  CalcarSocketClient({
    required this.baseUrl,
    required this.userId,
    required this.token,
    SocketChannelFactory? channelFactory,
    this.heartbeatInterval = const Duration(seconds: 30),
    int inboundCapacity = 64,
    this.onCatchupNeeded,
    this.onConnectionLost,
  })  : _buffer = InboundBuffer<SocketEvent>(capacity: inboundCapacity),
        _channelFactory = channelFactory ??
            ((Uri uri, Iterable<String>? protocols) =>
                WebSocketChannel.connect(uri, protocols: protocols));

  /// Typed server events. Heartbeats are consumed internally, not emitted.
  Stream<SocketEvent> get events => _events.stream;

  /// False after [dispose]. While false, no reconnect may dial.
  bool get isMounted => _mounted;

  /// True while a channel object is attached.
  bool get isConnected => _channel != null;

  /// Latched when the inbound buffer overflowed. Refetch, then
  /// call [markCaughtUp].
  bool get needsCatchup => _buffer.needsCatchup;

  /// Total inbound drops since creation.
  int get droppedCount => _buffer.dropped;

  /// Consecutive silent heartbeat intervals.
  int get missedHeartbeats => _heartbeats.missed;

  /// Outbound subscribe body. Pure helper, no socket needed.
  static String subscribeMessage(String userId) {
    return jsonEncode(<String, dynamic>{
      'type': 'subscribe',
      'topic': 'user:$userId',
    });
  }

  /// Outbound heartbeat body. Pure helper, no socket needed.
  static String heartbeatMessage() {
    return jsonEncode(<String, dynamic>{'type': 'heartbeat'});
  }

  /// Dial string used by [connect]. Pure helper for tests and logs.
  /// Never includes secrets in log output; the token is in the query.
  Uri connectionUri() {
    final String trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse(
      '$trimmed/v1/ws?access_token=${Uri.encodeQueryComponent(token)}',
    );
  }

  /// Opens the socket, auto-subscribes, and starts the heartbeat timer.
  /// No-op when disposed or already connected. Failures schedule a
  /// backoff retry while still mounted.
  Future<void> connect() async {
    if (!_mounted || _disposed) {
      return;
    }
    if (_channel != null) {
      return;
    }
    WebSocketChannel channel;
    try {
      channel = _channelFactory(
        connectionUri(),
        const <String>['calcar-ws-v1'],
      );
      channel.sink.add(subscribeMessage(userId));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    _reconnects.reset();
    _heartbeats.reset();
    _startHeartbeatTimer();
    _subscription = channel.stream.listen(
      _onRaw,
      onError: (Object _, StackTrace __) => _handleDrop(),
      onDone: _handleDrop,
      cancelOnError: false,
    );
  }

  /// Idempotent foreground teardown. Closes the sink and channel,
  /// cancels heartbeat and reconnect timers, closes the event stream,
  /// and latches unmounted so pending timers never redial.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _mounted = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final StreamSubscription<dynamic>? sub = _subscription;
    _subscription = null;
    unawaited(sub?.cancel());
    final WebSocketChannel? channel = _channel;
    _channel = null;
    try {
      unawaited(channel?.sink.close());
    } catch (_) {
      // Close is best effort; the socket is gone either way.
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }

  /// Clears the catch-up flag after the snapshot refetch completes.
  void markCaughtUp() {
    _notifiedCatchup = false;
    _buffer.markCaughtUp();
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer ??= Timer.periodic(
      heartbeatInterval,
      (_) => _onHeartbeatTick(),
    );
  }

  void _onHeartbeatTick() {
    if (!_mounted || _disposed || _channel == null) {
      return;
    }
    try {
      _channel?.sink.add(heartbeatMessage());
    } catch (_) {
      _handleDrop();
      return;
    }
    if (_heartbeats.tick()) {
      _handleDrop();
    }
  }

  void _onRaw(dynamic raw) {
    if (!_mounted || _disposed) {
      return;
    }
    _heartbeats.markMessage();
    final Map<String, dynamic>? decoded = _decode(raw);
    if (decoded == null) {
      return;
    }
    final SocketEvent? event = parseEnvelope(decoded);
    if (event == null) {
      // Unknown type, bad version, or malformed envelope: ignore.
      return;
    }
    if (event is HeartbeatEvent) {
      return;
    }
    if (!_buffer.add(event)) {
      if (!_notifiedCatchup) {
        _notifiedCatchup = true;
        onCatchupNeeded?.call();
      }
      return;
    }
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  Map<String, dynamic>? _decode(dynamic raw) {
    try {
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return <String, dynamic>{
          for (final MapEntry<dynamic, dynamic> e in decoded.entries)
            '${e.key}': e.value,
        };
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _handleDrop() {
    if (!_mounted || _disposed) {
      return;
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
    final WebSocketChannel? channel = _channel;
    _channel = null;
    try {
      unawaited(channel?.sink.close());
    } catch (_) {
      // Best effort; reconnect path replaces the channel.
    }
    onConnectionLost?.call();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_mounted || _disposed) {
      return;
    }
    if (_reconnectTimer?.isActive ?? false) {
      return;
    }
    final Duration delay = _reconnects.nextDelay();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!ReconnectPolicy.shouldReconnect(mounted: _mounted) || _disposed) {
        return;
      }
      unawaited(connect());
    });
  }
}
