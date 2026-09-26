/// API client contract tests. Canned JSON maps only, no network:
/// every backend reply comes from an in-memory MockClient.
/// Each test names the contract it guards.
import 'dart:convert';

import 'package:calcar/api/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Client whose next reply is the canned (status, error-code) body.
CalcarApiClient errorClient(int status, String code) {
  return CalcarApiClient(
    baseUrl: 'https://backend.test',
    token: 'tok-123',
    httpClient: MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error': code,
          'message': 'canned',
          'retryable': false,
        },),
        status,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }),
  );
}

void main() {
  group('error mapping guards the pairing-spec section 12 code table', () {
    test('contract: 400 preserves INVALID_INPUT without remap', () {
      expect(
        errorClient(400, ApiCodes.invalidInput).listDevices(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'INVALID_INPUT'),
        ),
      );
    });

    test('contract: 401 preserves REVOKED for revoked devices', () {
      expect(
        errorClient(401, ApiCodes.revoked).listDevices(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'REVOKED')
              .having((e) => e.status, 'status', 401),
        ),
      );
    });

    test('contract: 403 preserves NOT_OWNER for computer callers', () {
      expect(
        errorClient(403, ApiCodes.notOwner).trustGraph(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'NOT_OWNER')
              .having((e) => e.status, 'status', 403),
        ),
      );
    });

    test('contract: 409 preserves REPLAYED_ID for reused request ids', () {
      expect(
        errorClient(409, ApiCodes.replayedId).listDevices(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'REPLAYED_ID'),
        ),
      );
    });

    test('contract: 410 preserves PAIRING_EXPIRED for joins after TTL', () {
      expect(
        errorClient(410, ApiCodes.pairingExpired).getPairingSession('s-1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'PAIRING_EXPIRED')
              .having((e) => e.status, 'status', 410),
        ),
      );
    });

    test('contract: 410 preserves PAIRING_CONSUMED for second decisions', () {
      expect(
        errorClient(410, ApiCodes.pairingConsumed).decidePairingSession(
          's-1',
          'req-1',
          approve: true,
          subjectPubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'PAIRING_CONSUMED'),
        ),
      );
    });

    test('contract: 422 preserves PUBKEY_MISMATCH for swapped keys', () {
      expect(
        errorClient(422, ApiCodes.pubkeyMismatch).decidePairingSession(
          's-1',
          'req-1',
          approve: true,
          subjectPubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'PUBKEY_MISMATCH'),
        ),
      );
    });

    test('contract: 422 preserves QR_MISMATCH for wrong QR nonce', () {
      expect(
        errorClient(422, ApiCodes.qrMismatch).joinPairingSession(
          's-1',
          pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          fingerprint: 'fp',
          displayName: 'pc',
          requestId: 'req-1',
          qrNonce: 'wrong',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'QR_MISMATCH'),
        ),
      );
    });

    test(
      'contract: non-JSON body falls back to the status-derived code',
      () {
        final CalcarApiClient client = CalcarApiClient(
          baseUrl: 'https://backend.test',
          token: 'tok-123',
          httpClient: MockClient((http.Request request) async {
            return http.Response('not json', 409);
          }),
        );
        expect(
          client.listDevices(),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'REPLAYED_ID'),
          ),
        );
      },
    );
  });

  group('request bodies mirror backend/api JSON shapes exactly', () {
    test('contract: join body carries the five backend keys verbatim', () {
      final Map<String, dynamic> body = buildJoinBody(
        pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        fingerprint: 'A91C 7D24',
        displayName: 'WIN-PC',
        requestId: 'req-1',
        qrNonce: 'qr-nonce',
      );
      expect(
        body.keys.toSet(),
        <String>{
          'pubkey_b64',
          'fingerprint',
          'display_name',
          'request_id',
          'qr_nonce',
        },
      );
      expect(body['display_name'], 'WIN-PC');
    });

    test('contract: decision body carries the six backend keys verbatim', () {
      final Map<String, dynamic> body = buildDecisionBody(
        approve: true,
        subjectPubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        signatureB64: 'sig',
        authorizationId: 'auth-1',
        nonceB64: 'nonce',
        decidedAtMillis: 1700000000000,
      );
      expect(
        body.keys.toSet(),
        <String>{
          'approve',
          'subject_pubkey_b64',
          'signature_b64',
          'authorization_id',
          'nonce_b64',
          'decided_at_millis',
        },
      );
      expect(body['approve'], isTrue);
    });

    test('contract: join sends the exact keys over the wire', () async {
      Map<String, dynamic>? seen;
      final CalcarApiClient client = CalcarApiClient(
        baseUrl: 'https://backend.test',
        httpClient: MockClient((http.Request request) async {
          seen = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response(
            jsonEncode(<String, dynamic>{
              'session_id': 's-1',
              'status': 'pending',
            },),
            200,
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }),
      );
      final PairingJoinResult result = await client.joinPairingSession(
        's-1',
        pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        fingerprint: 'A91C 7D24',
        displayName: 'WIN-PC',
        requestId: 'req-1',
        qrNonce: 'qr-nonce',
      );
      expect(result.sessionId, 's-1');
      expect(
        seen!.keys.toSet(),
        <String>{
          'pubkey_b64',
          'fingerprint',
          'display_name',
          'request_id',
          'qr_nonce',
        },
      );
    });

    test('contract: decision sends the exact keys over the wire', () async {
      Map<String, dynamic>? seen;
      final CalcarApiClient client = CalcarApiClient(
        baseUrl: 'https://backend.test',
        token: 'tok-123',
        httpClient: MockClient((http.Request request) async {
          seen = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response(
            jsonEncode(<String, dynamic>{
              'session_id': 's-1',
              'status': 'rejected',
            },),
            200,
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }),
      );
      final PairingDecisionResult result = await client.decidePairingSession(
        's-1',
        'req-9',
        approve: false,
        subjectPubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      );
      expect(result.status, 'rejected');
      expect(
        seen!.keys.toSet(),
        <String>{
          'approve',
          'subject_pubkey_b64',
          'signature_b64',
          'authorization_id',
          'nonce_b64',
          'decided_at_millis',
        },
      );
    });
  });

  group('auth transport', () {
    test('contract: bearer token travels as the Authorization header', () async {
      String? seenAuth;
      final CalcarApiClient client = CalcarApiClient(
        baseUrl: 'https://backend.test',
        token: 'tok-123',
        httpClient: MockClient((http.Request request) async {
          seenAuth = request.headers['Authorization'];
          return http.Response(
            jsonEncode(<String, dynamic>{'devices': <dynamic>[]}),
            200,
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }),
      );
      await client.listDevices();
      expect(seenAuth, 'Bearer tok-123');
    });

    test('contract: verify stores access_token for later calls', () async {
      final List<String?> seenAuth = <String?>[];
      final CalcarApiClient client = CalcarApiClient(
        baseUrl: 'https://backend.test',
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/v1/auth/verify') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'access_token': 'fresh-tok',
                'token_type': 'bearer',
                'expires_in_seconds': 86400,
              },),
              200,
              headers: <String, String>{'Content-Type': 'application/json'},
            );
          }
          seenAuth.add(request.headers['Authorization']);
          return http.Response(
            jsonEncode(<String, dynamic>{'devices': <dynamic>[]}),
            200,
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }),
      );
      final TokenResponse token = await client.verify(
        deviceId: 'PH-1',
        challenge: 'ch',
        signatureB64: 'sig',
      );
      expect(token.accessToken, 'fresh-tok');
      expect(client.token, 'fresh-tok');
      await client.listDevices();
      expect(seenAuth, <String?>['Bearer fresh-tok']);
    });
  });
}
