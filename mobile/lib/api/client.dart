/// Typed HTTP client for the P3 control plane.
///
/// Thin transport only: bearer token holder, exact backend JSON shapes,
/// stable spec error codes via [ApiException]. No provider logic, no state
/// management, no caching. One class plus pure body builders.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'models.dart';
import 'request_bodies.dart';

class CalcarApiClient {
  final String baseUrl;
  final http.Client _http;

  /// Current bearer token, null when logged out.
  String? token;

  CalcarApiClient({
    required String baseUrl,
    http.Client? httpClient,
    this.token,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _http = httpClient ?? http.Client();

  /// Drops the bearer token without any network call.
  void clearToken() => token = null;

  // ---- auth ----

  /// POST /v1/auth/challenge. No token needed.
  Future<ChallengeResponse> challenge(String deviceId) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/auth/challenge'),
        headers: _headers(),
        body: jsonEncode(buildChallengeBody(deviceId: deviceId)),
      ),
    );
    return ChallengeResponse.fromJson(body);
  }

  /// POST /v1/auth/verify. Stores the access token on success and
  /// returns the full token response.
  Future<TokenResponse> verify({
    required String deviceId,
    required String challenge,
    required String signatureB64,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/auth/verify'),
        headers: _headers(),
        body: jsonEncode(
          buildVerifyBody(
            deviceId: deviceId,
            challenge: challenge,
            signatureB64: signatureB64,
          ),
        ),
      ),
    );
    final TokenResponse resp = TokenResponse.fromJson(body);
    token = resp.accessToken;
    return resp;
  }

  /// POST /v1/users/bootstrap. Needs `X-Request-ID`, no token yet.
  Future<BootstrapResult> bootstrapOwner({
    required String displayName,
    required String pubkeyB64,
    required String deviceId,
    required String requestId,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/users/bootstrap'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(
          buildBootstrapBody(
            displayName: displayName,
            pubkeyB64: pubkeyB64,
            deviceId: deviceId,
          ),
        ),
      ),
    );
    return BootstrapResult.fromJson(body);
  }

  // ---- devices / trust ----

  /// GET /v1/devices.
  Future<List<Device>> listDevices() async {
    final Map<String, dynamic> body = _checked(
      await _http.get(_uri('/v1/devices'), headers: _headers()),
    );
    final dynamic raw = body['devices'];
    if (raw is! List) {
      return <Device>[];
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Device.fromJson)
        .toList(growable: false);
  }

  /// GET /v1/trust/graph.
  Future<TrustGraph> trustGraph() async {
    final Map<String, dynamic> body = _checked(
      await _http.get(_uri('/v1/trust/graph'), headers: _headers()),
    );
    return TrustGraph.fromJson(body);
  }

  /// POST /v1/devices/{id}/revoke.
  Future<RevokeResult> revokeDevice(
    String deviceId,
    String requestId, {
    String reason = '',
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/devices/${Uri.encodeComponent(deviceId)}/revoke'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(buildRevokeBody(reason: reason)),
      ),
    );
    return RevokeResult.fromJson(body);
  }

  /// POST /v1/devices/{id}/push-token.
  Future<PushTokenResult> postPushToken(
    String deviceId,
    String requestId, {
    required String platform,
    required String pushToken,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/devices/${Uri.encodeComponent(deviceId)}/push-token'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(
          buildPushTokenBody(platform: platform, pushToken: pushToken),
        ),
      ),
    );
    return PushTokenResult.fromJson(body);
  }

  // ---- pairing ----

  /// POST /v1/pairing/sessions. Phones only; computers get 403.
  Future<PairingSession> createPairingSession(String requestId) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/pairing/sessions'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(<String, dynamic>{}),
      ),
    );
    return PairingSession.fromJson(body);
  }

  /// POST /v1/pairing/sessions/{id}/join-request. Unauthenticated: the
  /// body `request_id` doubles as the idempotency key, so no header and
  /// no token are sent.
  Future<PairingJoinResult> joinPairingSession(
    String sessionId, {
    required String pubkeyB64,
    required String fingerprint,
    required String displayName,
    required String requestId,
    required String qrNonce,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri(
          '/v1/pairing/sessions/${Uri.encodeComponent(sessionId)}/join-request',
        ),
        headers: _headers(),
        body: jsonEncode(
          buildJoinBody(
            pubkeyB64: pubkeyB64,
            fingerprint: fingerprint,
            displayName: displayName,
            requestId: requestId,
            qrNonce: qrNonce,
          ),
        ),
      ),
    );
    return PairingJoinResult.fromJson(body);
  }

  /// GET /v1/pairing/sessions/{id}. Only the creating phone may read it.
  Future<PairingSession> getPairingSession(String sessionId) async {
    final Map<String, dynamic> body = _checked(
      await _http.get(
        _uri('/v1/pairing/sessions/${Uri.encodeComponent(sessionId)}'),
        headers: _headers(),
      ),
    );
    return PairingSession.fromJson(body);
  }

  /// POST /v1/pairing/sessions/{id}/decision. Caller must be the active
  /// Owner device; computers get 403 and never a grant.
  Future<PairingDecisionResult> decidePairingSession(
    String sessionId,
    String requestId, {
    required bool approve,
    required String subjectPubkeyB64,
    String signatureB64 = '',
    String authorizationId = '',
    String nonceB64 = '',
    int decidedAtMillis = 0,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri(
          '/v1/pairing/sessions/${Uri.encodeComponent(sessionId)}/decision',
        ),
        headers: _headers(requestId: requestId),
        body: jsonEncode(
          buildDecisionBody(
            approve: approve,
            subjectPubkeyB64: subjectPubkeyB64,
            signatureB64: signatureB64,
            authorizationId: authorizationId,
            nonceB64: nonceB64,
            decidedAtMillis: decidedAtMillis,
          ),
        ),
      ),
    );
    return PairingDecisionResult.fromJson(body);
  }

  // ---- presence / attention ----

  /// POST /v1/presence/heartbeat.
  Future<Presence> heartbeat(String requestId, {bool? online}) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/presence/heartbeat'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(buildHeartbeatBody(online: online)),
      ),
    );
    return Presence.fromJson(body);
  }

  /// GET /v1/computers/{id}/presence.
  Future<Presence> getPresence(String computerId) async {
    final Map<String, dynamic> body = _checked(
      await _http.get(
        _uri('/v1/computers/${Uri.encodeComponent(computerId)}/presence'),
        headers: _headers(),
      ),
    );
    return Presence.fromJson(body);
  }

  /// POST /v1/notify/attention. Only the owning computer posts; the phone
  /// client exposes this for completeness and tests.
  Future<bool> postAttention(
    String requestId, {
    required String computerId,
    required String workflowId,
    required String kind,
  }) async {
    final Map<String, dynamic> body = _checked(
      await _http.post(
        _uri('/v1/notify/attention'),
        headers: _headers(requestId: requestId),
        body: jsonEncode(
          buildAttentionBody(
            computerId: computerId,
            workflowId: workflowId,
            kind: kind,
          ),
        ),
      ),
    );
    return body['queued'] == true;
  }

  // ---- transport ----

  Map<String, String> _headers({String? requestId}) {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (requestId != null) {
      headers['X-Request-ID'] = requestId;
    }
    return headers;
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Returns the decoded JSON map for 2xx, else throws [ApiException]
  /// carrying the stable spec code from the `error` field.
  Map<String, dynamic> _checked(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) {
        return <String, dynamic>{};
      }
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return <String, dynamic>{'value': decoded};
    }
    Map<String, dynamic>? body;
    try {
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      } else if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      body = null;
    }
    throw ApiException.fromBody(res.statusCode, body);
  }
}
