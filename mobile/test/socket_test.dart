import 'package:calcar/realtime/heartbeat_tracker.dart';
import 'package:calcar/realtime/inbound_buffer.dart';
import 'package:calcar/realtime/reconnect_policy.dart';
import 'package:calcar/realtime/socket_client.dart';
import 'package:calcar/realtime/socket_event.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 2 gate: envelope parsing, heartbeat accounting, bounded
// buffer, and dispose-gated reconnect. Canned maps only, no sockets.

Map<String, dynamic> _envelope(String type) {
  return <String, dynamic>{
    'protocol_version': '1.0',
    'msg_id': 'msg-$type',
    'type': type,
    'to': 'user:u1',
    'payload': <String, dynamic>{'k': 'v'},
  };
}

void main() {
  group('envelope parsing', () {
    test('contract: pairing.join_requested parses to PairingJoinRequested', () {
      final SocketEvent? event = parseEnvelope(
        _envelope('pairing.join_requested'),
      );
      expect(event, isA<PairingJoinRequested>());
      expect(event?.msgId, 'msg-pairing.join_requested');
      expect(event?.to, 'user:u1');
    });

    test('contract: pairing.decided parses to PairingDecided', () {
      expect(
        parseEnvelope(_envelope('pairing.decided')),
        isA<PairingDecided>(),
      );
    });

    test('contract: attention.pending parses to AttentionPending', () {
      expect(
        parseEnvelope(_envelope('attention.pending')),
        isA<AttentionPending>(),
      );
    });

    test('contract: presence.changed parses to PresenceChanged', () {
      expect(
        parseEnvelope(_envelope('presence.changed')),
        isA<PresenceChanged>(),
      );
    });

    test('contract: trust.revoked parses to TrustRevoked', () {
      expect(
        parseEnvelope(_envelope('trust.revoked')),
        isA<TrustRevoked>(),
      );
    });

    test('contract: heartbeat parses to HeartbeatEvent', () {
      expect(
        parseEnvelope(_envelope('heartbeat')),
        isA<HeartbeatEvent>(),
      );
    });

    test('contract: unknown types are ignored per additive-only rule', () {
      expect(parseEnvelope(_envelope('workflow.supernova')), isNull);
    });

    test('contract: unknown major protocol version is refused', () {
      final Map<String, dynamic> json = _envelope('heartbeat');
      json['protocol_version'] = '2.0';
      expect(parseEnvelope(json), isNull);
    });

    test('contract: envelope without msg_id is ignored', () {
      final Map<String, dynamic> json = _envelope('heartbeat');
      json.remove('msg_id');
      expect(parseEnvelope(json), isNull);
    });

    test('contract: minor version drift still parses', () {
      final Map<String, dynamic> json = _envelope('presence.changed');
      json['protocol_version'] = '1.7';
      expect(parseEnvelope(json), isA<PresenceChanged>());
    });
  });

  group('heartbeat accounting', () {
    test('contract: three silent intervals mark the socket dropped', () {
      final HeartbeatTracker tracker = HeartbeatTracker();
      expect(tracker.tick(), isFalse);
      expect(tracker.tick(), isFalse);
      expect(tracker.tick(), isTrue);
      expect(tracker.shouldDrop, isTrue);
      expect(tracker.missed, HeartbeatTracker.maxMissed);
    });

    test('contract: any inbound message resets the miss count', () {
      final HeartbeatTracker tracker = HeartbeatTracker();
      tracker.tick();
      tracker.tick();
      tracker.markMessage();
      expect(tracker.missed, 0);
      expect(tracker.shouldDrop, isFalse);
      expect(tracker.tick(), isFalse);
    });
  });

  group('inbound buffer', () {
    test('contract: overflow drops and latches catch-up', () {
      final InboundBuffer<String> buffer = InboundBuffer<String>(
        capacity: 2,
      );
      expect(buffer.add('a'), isTrue);
      expect(buffer.add('b'), isTrue);
      expect(buffer.add('c'), isFalse);
      expect(buffer.dropped, 1);
      expect(buffer.needsCatchup, isTrue);
      expect(buffer.items, <String>['a', 'b']);
    });

    test('contract: catch-up flag clears only after refetch', () {
      final InboundBuffer<String> buffer = InboundBuffer<String>(
        capacity: 1,
      );
      buffer.add('a');
      buffer.add('b');
      expect(buffer.needsCatchup, isTrue);
      buffer.markCaughtUp();
      expect(buffer.needsCatchup, isFalse);
      expect(buffer.dropped, 1);
    });
  });

  group('reconnect and dispose', () {
    test('contract: backoff grows and resets after success', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      final Duration first = policy.nextDelay();
      final Duration second = policy.nextDelay();
      expect(second >= first, isTrue);
      policy.reset();
      expect(policy.attempts, 0);
      expect(policy.nextDelay(), first);
    });

    test('contract: reconnect runs only while mounted', () {
      expect(
        ReconnectPolicy.shouldReconnect(mounted: true),
        isTrue,
      );
      expect(
        ReconnectPolicy.shouldReconnect(mounted: false),
        isFalse,
      );
    });

    test(
        'contract: dispose latches unmounted and blocks later connects', () async {
      int factoryCalls = 0;
      final CalcarSocketClient client = CalcarSocketClient(
        baseUrl: 'wss://example.invalid',
        userId: 'u1',
        token: 'tok',
        channelFactory: (Uri uri, Iterable<String>? protocols) {
          factoryCalls += 1;
          throw StateError('no sockets in unit tests');
        },
      );
      expect(client.isMounted, isTrue);
      await client.connect();
      expect(factoryCalls, 1);
      client.dispose();
      expect(client.isMounted, isFalse);
      // Dispose is idempotent and a post-dispose connect never dials.
      client.dispose();
      await client.connect();
      expect(factoryCalls, 1);
    });

    test('contract: subscribe and heartbeat bodies match hub inbound types',
        () {
      expect(
        CalcarSocketClient.subscribeMessage('u9'),
        contains('subscribe'),
      );
      expect(
        CalcarSocketClient.subscribeMessage('u9'),
        contains('user:u9'),
      );
      expect(
        CalcarSocketClient.heartbeatMessage(),
        contains('heartbeat'),
      );
    });
  });
}
