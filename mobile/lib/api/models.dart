/// Typed views over backend JSON. Field names mirror the backend exactly
/// (snake_case); parsing is defensive about missing optional keys but never
/// renames a wire field.
library;

class Device {
  final String deviceId;
  final String role;
  final String displayName;
  final String pubkeyB64;
  final String fingerprint;
  final bool revoked;
  final String authorizedBy;

  const Device({
    required this.deviceId,
    required this.role,
    required this.displayName,
    required this.pubkeyB64,
    required this.fingerprint,
    required this.revoked,
    required this.authorizedBy,
  });

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      deviceId: json['device_id']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      pubkeyB64: json['pubkey_b64']?.toString() ?? '',
      fingerprint: json['fingerprint']?.toString() ?? '',
      revoked: json['revoked'] == true,
      authorizedBy: json['authorized_by']?.toString() ?? '',
    );
  }
}

/// Pairing session record. Join fields appear only after a join request.
class PairingSession {
  final String sessionId;
  final String status;
  final String ownerDeviceId;
  final int expiresAtMillis;
  final String qrNonce;
  final String? joinRequestId;
  final String? joinFingerprint;
  final String? joinDisplayName;

  const PairingSession({
    required this.sessionId,
    required this.status,
    required this.ownerDeviceId,
    required this.expiresAtMillis,
    required this.qrNonce,
    this.joinRequestId,
    this.joinFingerprint,
    this.joinDisplayName,
  });

  factory PairingSession.fromJson(Map<String, dynamic> json) {
    return PairingSession(
      sessionId: json['session_id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      ownerDeviceId: json['owner_device_id']?.toString() ?? '',
      expiresAtMillis: _asInt(json['expires_at_millis']),
      qrNonce: json['qr_nonce']?.toString() ?? '',
      joinRequestId: json['join_request_id']?.toString(),
      joinFingerprint: json['join_fingerprint']?.toString(),
      joinDisplayName: json['join_display_name']?.toString(),
    );
  }
}

/// Result of the unauthenticated join call: `{session_id, status}`.
class PairingJoinResult {
  final String sessionId;
  final String status;

  const PairingJoinResult({required this.sessionId, required this.status});

  factory PairingJoinResult.fromJson(Map<String, dynamic> json) {
    return PairingJoinResult(
      sessionId: json['session_id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
    );
  }
}

/// Result of a pairing decision. `subjectDeviceId` is present on approve.
class PairingDecisionResult {
  final String sessionId;
  final String status;
  final String? subjectDeviceId;

  const PairingDecisionResult({
    required this.sessionId,
    required this.status,
    this.subjectDeviceId,
  });

  factory PairingDecisionResult.fromJson(Map<String, dynamic> json) {
    return PairingDecisionResult(
      sessionId: json['session_id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      subjectDeviceId: json['subject_device_id']?.toString(),
    );
  }
}

/// Challenge for key-possession login: `{device_id, challenge,
/// expires_in_seconds}`.
class ChallengeResponse {
  final String deviceId;
  final String challenge;
  final int expiresInSeconds;

  const ChallengeResponse({
    required this.deviceId,
    required this.challenge,
    required this.expiresInSeconds,
  });

  factory ChallengeResponse.fromJson(Map<String, dynamic> json) {
    return ChallengeResponse(
      deviceId: json['device_id']?.toString() ?? '',
      challenge: json['challenge']?.toString() ?? '',
      expiresInSeconds: _asInt(json['expires_in_seconds']),
    );
  }
}

/// Short-lived opaque token: `{access_token, token_type,
/// expires_in_seconds}`.
class TokenResponse {
  final String accessToken;
  final String tokenType;
  final int expiresInSeconds;

  const TokenResponse({
    required this.accessToken,
    required this.tokenType,
    required this.expiresInSeconds,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    return TokenResponse(
      accessToken: json['access_token']?.toString() ?? '',
      tokenType: json['token_type']?.toString() ?? '',
      expiresInSeconds: _asInt(json['expires_in_seconds']),
    );
  }
}

/// Owner bootstrap result: `{user_id, device_id, role, fingerprint}`.
class BootstrapResult {
  final String userId;
  final String deviceId;
  final String role;
  final String fingerprint;

  const BootstrapResult({
    required this.userId,
    required this.deviceId,
    required this.role,
    required this.fingerprint,
  });

  factory BootstrapResult.fromJson(Map<String, dynamic> json) {
    return BootstrapResult(
      userId: json['user_id']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      fingerprint: json['fingerprint']?.toString() ?? '',
    );
  }
}

/// Trust graph: `{devices, grants}`. Grants stay empty until the backend
/// seam gains grant listing; edges derive from `authorized_by` today.
class TrustGraph {
  final List<Device> devices;
  final List<Map<String, dynamic>> grants;

  const TrustGraph({required this.devices, required this.grants});

  factory TrustGraph.fromJson(Map<String, dynamic> json) {
    final List<Device> devices = <Device>[];
    final dynamic rawDevices = json['devices'];
    if (rawDevices is List) {
      for (final dynamic item in rawDevices) {
        if (item is Map<String, dynamic>) {
          devices.add(Device.fromJson(item));
        }
      }
    }
    final List<Map<String, dynamic>> grants = <Map<String, dynamic>>[];
    final dynamic rawGrants = json['grants'];
    if (rawGrants is List) {
      for (final dynamic item in rawGrants) {
        if (item is Map<String, dynamic>) {
          grants.add(item);
        } else if (item is Map) {
          grants.add(Map<String, dynamic>.from(item));
        }
      }
    }
    return TrustGraph(devices: devices, grants: grants);
  }
}

/// Presence record: `{device_id, online, last_seen_millis}`.
class Presence {
  final String deviceId;
  final bool online;
  final int lastSeenMillis;

  const Presence({
    required this.deviceId,
    required this.online,
    required this.lastSeenMillis,
  });

  factory Presence.fromJson(Map<String, dynamic> json) {
    return Presence(
      deviceId: json['device_id']?.toString() ?? '',
      online: json['online'] == true,
      lastSeenMillis: _asInt(json['last_seen_millis']),
    );
  }
}

/// Revoke result: `{device_id, revoked}`.
class RevokeResult {
  final String deviceId;
  final bool revoked;

  const RevokeResult({required this.deviceId, required this.revoked});

  factory RevokeResult.fromJson(Map<String, dynamic> json) {
    return RevokeResult(
      deviceId: json['device_id']?.toString() ?? '',
      revoked: json['revoked'] == true,
    );
  }
}

/// Push-token result: `{device_id, platform}`.
class PushTokenResult {
  final String deviceId;
  final String platform;

  const PushTokenResult({required this.deviceId, required this.platform});

  factory PushTokenResult.fromJson(Map<String, dynamic> json) {
    return PushTokenResult(
      deviceId: json['device_id']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
    );
  }
}

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
