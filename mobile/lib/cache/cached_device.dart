// One cached device row: the Device fields the cold start paints,
// plus the write stamp that orders the bounded trim.
//
// Stored with snake_case columns matching the backend wire names, so a
// cached row reads exactly like the snapshot it came from. [revoked] is
// an INTEGER 0/1 in SQLite and a bool in memory. [fromMap] returns null
// for a row without a device id, which is how [CacheStore] skips corrupt
// rows instead of painting a blank one.
library;

import 'package:calcar/api/models.dart';

/// Table holding the last foreground device snapshot.
const String cacheDevicesTable = 'devices';

/// Column names. They mirror the backend wire fields verbatim.
const String colDeviceId = 'device_id';
const String colDisplayName = 'display_name';
const String colRole = 'role';
const String colFingerprint = 'fingerprint';
const String colRevoked = 'revoked';
const String colAuthorizedBy = 'authorized_by';
const String colCachedAtMillis = 'cached_at_millis';

/// One device row as cached on disk.
class CachedDevice {
  final String deviceId;
  final String displayName;
  final String role;
  final String fingerprint;
  final bool revoked;
  final String authorizedBy;
  final int cachedAtMillis;

  const CachedDevice({
    required this.deviceId,
    required this.displayName,
    required this.role,
    required this.fingerprint,
    required this.revoked,
    required this.authorizedBy,
    required this.cachedAtMillis,
  });

  /// Copies a live snapshot row into a cache row stamped at [cachedAtMillis].
  factory CachedDevice.fromDevice(
    Device device, {
    required int cachedAtMillis,
  }) {
    return CachedDevice(
      deviceId: device.deviceId,
      displayName: device.displayName,
      role: device.role,
      fingerprint: device.fingerprint,
      revoked: device.revoked,
      authorizedBy: device.authorizedBy,
      cachedAtMillis: cachedAtMillis,
    );
  }

  /// Reads a row back. Null when the row has no device id, so the store
  /// can skip it: a blank id would key every corrupt row off one id and
  /// collapse them into each other on the next insert.
  static CachedDevice? fromMap(Map<String, Object?> map) {
    final String deviceId = map[colDeviceId]?.toString() ?? '';
    if (deviceId.isEmpty) {
      return null;
    }
    final Object? revokedRaw = map[colRevoked];
    final bool revoked =
        revokedRaw is int ? revokedRaw != 0 : revokedRaw == true;
    return CachedDevice(
      deviceId: deviceId,
      displayName: map[colDisplayName]?.toString() ?? '',
      role: map[colRole]?.toString() ?? '',
      fingerprint: map[colFingerprint]?.toString() ?? '',
      revoked: revoked,
      authorizedBy: map[colAuthorizedBy]?.toString() ?? '',
      cachedAtMillis: _asIntMillis(map[colCachedAtMillis]),
    );
  }

  /// Writes the row for SQLite. Revoked goes out as 0/1.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      colDeviceId: deviceId,
      colDisplayName: displayName,
      colRole: role,
      colFingerprint: fingerprint,
      colRevoked: revoked ? 1 : 0,
      colAuthorizedBy: authorizedBy,
      colCachedAtMillis: cachedAtMillis,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is CachedDevice &&
        other.deviceId == deviceId &&
        other.displayName == displayName &&
        other.role == role &&
        other.fingerprint == fingerprint &&
        other.revoked == revoked &&
        other.authorizedBy == authorizedBy &&
        other.cachedAtMillis == cachedAtMillis;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        displayName,
        role,
        fingerprint,
        revoked,
        authorizedBy,
        cachedAtMillis,
      );

  @override
  String toString() {
    return 'CachedDevice($deviceId, $role, revoked=$revoked)';
  }
}

int _asIntMillis(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
