// Foreground-only realtime event model for the P3 signal plane.
//
// Mirrors backend/ws/hub.go: every server message is an envelope with
// protocol_version, msg_id, type, to, payload. Unknown types and unknown
// fields are ignored so old clients survive additive changes. Unknown
// major protocol versions are refused (parse returns null).
//
// No sockets here. No background handling here. The socket client in
// socket_client.dart owns the connection; this file only types events.

/// Wire protocol version spoken by backend/ws/hub.go.
const String kProtocolVersion = '1.0';

/// Server-sent event types. Stable strings, additive only.
const String kEventPairingJoinRequested = 'pairing.join_requested';
const String kEventPairingDecided = 'pairing.decided';
const String kEventAttentionPending = 'attention.pending';
const String kEventPresenceChanged = 'presence.changed';
const String kEventTrustRevoked = 'trust.revoked';
const String kEventHeartbeat = 'heartbeat';

/// Every typed event the socket client surfaces.
const Set<String> kKnownEventTypes = <String>{
  kEventPairingJoinRequested,
  kEventPairingDecided,
  kEventAttentionPending,
  kEventPresenceChanged,
  kEventTrustRevoked,
  kEventHeartbeat,
};

/// Base of all parsed server events.
sealed class SocketEvent {
  /// Envelope msg_id. Opaque, used for dedupe and logs only.
  final String msgId;

  /// Envelope routing hint. Either a device id or `user:<userId>`.
  final String to;

  /// Envelope payload. Shapes vary per type; unknown keys are ignored.
  final Map<String, dynamic> payload;

  const SocketEvent({
    required this.msgId,
    required this.to,
    required this.payload,
  });

  /// Wire `type` string for this event.
  String get type;
}

/// Owner phone received a PC join request for a pairing session.
final class PairingJoinRequested extends SocketEvent {
  const PairingJoinRequested({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventPairingJoinRequested;
}

/// A pairing session was approved, rejected, or expired.
final class PairingDecided extends SocketEvent {
  const PairingDecided({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventPairingDecided;
}

/// Server dropped messages or queued work; refetch over authed HTTP.
final class AttentionPending extends SocketEvent {
  const AttentionPending({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventAttentionPending;
}

/// A device went online or offline.
final class PresenceChanged extends SocketEvent {
  const PresenceChanged({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventPresenceChanged;
}

/// A device trust grant was revoked. Caller must refetch and enforce.
final class TrustRevoked extends SocketEvent {
  const TrustRevoked({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventTrustRevoked;
}

/// Server heartbeat. Resets the missed-heartbeat counter, never UI state.
final class HeartbeatEvent extends SocketEvent {
  const HeartbeatEvent({
    required super.msgId,
    required super.to,
    required super.payload,
  });

  @override
  String get type => kEventHeartbeat;
}

/// Parses one decoded JSON envelope map into a typed [SocketEvent].
///
/// Returns null when the envelope must be ignored: unknown event type,
/// unknown major protocol version, or missing msg_id/type. Never throws
/// on shape drift; unknown payload fields pass through untouched.
SocketEvent? parseEnvelope(Map<String, dynamic> json) {
  final Object? version = json['protocol_version'];
  if (version is! String || !_sameMajor(version, kProtocolVersion)) {
    return null;
  }
  final Object? rawId = json['msg_id'];
  final Object? rawType = json['type'];
  if (rawId is! String || rawId.isEmpty) {
    return null;
  }
  if (rawType is! String || rawType.isEmpty) {
    return null;
  }
  final String to = json['to'] is String ? json['to'] as String : '';
  final Map<String, dynamic> payload = _payloadOf(json['payload']);

  switch (rawType) {
    case kEventPairingJoinRequested:
      return PairingJoinRequested(msgId: rawId, to: to, payload: payload);
    case kEventPairingDecided:
      return PairingDecided(msgId: rawId, to: to, payload: payload);
    case kEventAttentionPending:
      return AttentionPending(msgId: rawId, to: to, payload: payload);
    case kEventPresenceChanged:
      return PresenceChanged(msgId: rawId, to: to, payload: payload);
    case kEventTrustRevoked:
      return TrustRevoked(msgId: rawId, to: to, payload: payload);
    case kEventHeartbeat:
      return HeartbeatEvent(msgId: rawId, to: to, payload: payload);
    default:
      // Additive-only rule: future server types must not break old phones.
      return null;
  }
}

bool _sameMajor(String got, String want) {
  final String gotMajor = got.split('.').first;
  final String wantMajor = want.split('.').first;
  return gotMajor.isNotEmpty && gotMajor == wantMajor;
}

Map<String, dynamic> _payloadOf(Object? raw) {
  if (raw == null) {
    return <String, dynamic>{};
  }
  if (raw is Map<String, dynamic>) {
    return Map<String, dynamic>.from(raw);
  }
  if (raw is Map) {
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> e in raw.entries)
        '${e.key}': e.value,
    };
  }
  return <String, dynamic>{'value': raw};
}
