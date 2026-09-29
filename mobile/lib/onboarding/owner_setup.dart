// Owner setup orchestration: biometric unlock, then key generation,
// then the bootstrap call, then the challenge plus verify login. Order
// is the contract: no unlock means no key, no key means no network
// call, bootstrap without login leaves a registered phone with no
// token, so every authed call after would 401. A failed bootstrap or
// login deletes the key so no partial Owner ever lingers. Recovery
// credentials stay outside this flow by design.
library;

import 'dart:convert';

import 'package:calcar/api/api.dart';
import 'package:calcar/auth/session_store.dart';
import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/screens/first_run.dart';

/// Establishes this phone as Owner. Returns true only when the server
/// accepted the bootstrap and the challenge plus verify login stored a
/// bearer token on the client. Persists the session when a store is
/// given, so a returning phone unlocks instead of redoing setup.
/// Injected seams only, so tests never touch
/// hardware, storage, or the network.
Future<bool> establishOwner({
  required String displayName,
  required OwnerKeyService keys,
  required LocalAuthGate gate,
  required CalcarApiClient api,
  required String requestId,
  SessionStore? session,
}) async {
  if (displayName.trim().isEmpty) {
    return false;
  }
  final LocalAuthResult auth = await gate.authenticate(
    reason: 'Unlock to establish this phone as Owner',
  );
  if (auth != LocalAuthResult.unlocked) {
    return false;
  }
  try {
    await keys.generate();
    final List<int> pub = await keys.publicKey();
    final BootstrapResult boot = await api.bootstrapOwner(
      displayName: displayName.trim(),
      pubkeyB64: base64Encode(pub),
      deviceId: '',
      requestId: requestId,
    );
    // Bootstrap registers but mints no token. The Owner signs the fresh
    // challenge with the key just generated, and verify stores the bearer
    // token on the client for every call after this one.
    final ChallengeResponse ch = await api.challenge(boot.deviceId);
    final List<int> sig = await keys.sign(utf8.encode(ch.challenge));
    await api.verify(
      deviceId: boot.deviceId,
      challenge: ch.challenge,
      signatureB64: base64Encode(sig),
    );
    api.deviceId = boot.deviceId;
    api.userId = boot.userId;
    final String? token = api.token;
    if (token == null || token.isEmpty) {
      throw StateError('login minted no token');
    }
    await session?.save(
      OwnerSession(
        deviceId: boot.deviceId,
        userId: boot.userId,
        token: token,
      ),
    );
    return true;
  } on Object catch (_) {
    await keys.deleteKey();
    return false;
  }
}
