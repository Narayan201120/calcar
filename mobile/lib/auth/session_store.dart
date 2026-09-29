// Owner session persistence. The login token, device id, and user id
// survive app restarts in the hardware-wrapped store so a returning
// phone opens the lock instead of redoing Owner setup. A partial
// record loads as nothing and clears itself: a half-written session
// must never authenticate halfway.
library;

import 'package:calcar/keys/owner_keys.dart';

class OwnerSession {
  final String deviceId;
  final String userId;
  final String token;

  const OwnerSession({
    required this.deviceId,
    required this.userId,
    required this.token,
  });

  @override
  bool operator ==(Object other) {
    return other is OwnerSession &&
        other.deviceId == deviceId &&
        other.userId == userId &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(deviceId, userId, token);
}

class SessionStore {
  SessionStore({SeedStore? store})
      : _store = store ?? const SecureSeedStore();

  static const String deviceKey = 'calcar_session_device';
  static const String userKey = 'calcar_session_user';
  static const String tokenKey = 'calcar_session_token';

  final SeedStore _store;

  Future<void> save(OwnerSession session) async {
    await _store.write(deviceKey, session.deviceId);
    await _store.write(userKey, session.userId);
    await _store.write(tokenKey, session.token);
  }

  Future<OwnerSession?> load() async {
    final String? deviceId = await _store.read(deviceKey);
    final String? userId = await _store.read(userKey);
    final String? token = await _store.read(tokenKey);
    if (deviceId == null ||
        deviceId.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        token == null ||
        token.isEmpty) {
      await clear();
      return null;
    }
    return OwnerSession(deviceId: deviceId, userId: userId, token: token);
  }

  Future<void> clear() async {
    await _store.delete(deviceKey);
    await _store.delete(userKey);
    await _store.delete(tokenKey);
  }
}
