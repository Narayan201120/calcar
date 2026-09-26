/// Pure request-body builders. JSON keys mirror `backend/api` exactly.
/// No I/O, no state: covered by unit tests against the backend shapes.
library;

/// POST /v1/pairing/sessions/{id}/join-request (unauthenticated).
Map<String, dynamic> buildJoinBody({
  required String pubkeyB64,
  required String fingerprint,
  required String displayName,
  required String requestId,
  required String qrNonce,
}) {
  return <String, dynamic>{
    'pubkey_b64': pubkeyB64,
    'fingerprint': fingerprint,
    'display_name': displayName,
    'request_id': requestId,
    'qr_nonce': qrNonce,
  };
}

/// POST /v1/pairing/sessions/{id}/decision.
Map<String, dynamic> buildDecisionBody({
  required bool approve,
  required String subjectPubkeyB64,
  String signatureB64 = '',
  String authorizationId = '',
  String nonceB64 = '',
  int decidedAtMillis = 0,
}) {
  return <String, dynamic>{
    'approve': approve,
    'subject_pubkey_b64': subjectPubkeyB64,
    'signature_b64': signatureB64,
    'authorization_id': authorizationId,
    'nonce_b64': nonceB64,
    'decided_at_millis': decidedAtMillis,
  };
}

/// POST /v1/users/bootstrap.
Map<String, dynamic> buildBootstrapBody({
  required String displayName,
  required String pubkeyB64,
  required String deviceId,
}) {
  return <String, dynamic>{
    'display_name': displayName,
    'pubkey_b64': pubkeyB64,
    'device_id': deviceId,
  };
}

/// POST /v1/auth/challenge.
Map<String, dynamic> buildChallengeBody({required String deviceId}) {
  return <String, dynamic>{'device_id': deviceId};
}

/// POST /v1/auth/verify.
Map<String, dynamic> buildVerifyBody({
  required String deviceId,
  required String challenge,
  required String signatureB64,
}) {
  return <String, dynamic>{
    'device_id': deviceId,
    'challenge': challenge,
    'signature_b64': signatureB64,
  };
}

/// POST /v1/devices/{id}/revoke.
Map<String, dynamic> buildRevokeBody({String reason = ''}) {
  return <String, dynamic>{'reason': reason};
}

/// POST /v1/presence/heartbeat. Null `online` sends an empty object and
/// the backend defaults to online.
Map<String, dynamic> buildHeartbeatBody({bool? online}) {
  if (online == null) {
    return <String, dynamic>{};
  }
  return <String, dynamic>{'online': online};
}

/// POST /v1/notify/attention. Ids plus kind only, never bodies.
Map<String, dynamic> buildAttentionBody({
  required String computerId,
  required String workflowId,
  required String kind,
}) {
  return <String, dynamic>{
    'computer_id': computerId,
    'workflow_id': workflowId,
    'kind': kind,
  };
}

/// POST /v1/devices/{id}/push-token.
Map<String, dynamic> buildPushTokenBody({
  required String platform,
  required String pushToken,
}) {
  return <String, dynamic>{
    'platform': platform,
    'push_token': pushToken,
  };
}
