// Owner setup orchestration: biometric unlock, then key generation,
// then the bootstrap call. Order is the contract: no unlock means no
// key, no key means no network call, and a failed bootstrap deletes
// the key so no partial Owner ever lingers. Recovery credentials stay
// outside this flow by design.
library;

import 'dart:convert';

import 'package:calcar/api/api.dart';
import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/screens/first_run.dart';

/// Establishes this phone as Owner. Returns true only when the server
/// accepted the bootstrap. Injected seams only, so tests never touch
/// hardware, storage, or the network.
Future<bool> establishOwner({
  required String displayName,
  required OwnerKeyService keys,
  required LocalAuthGate gate,
  required CalcarApiClient api,
  required String requestId,
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
    await api.bootstrapOwner(
      displayName: displayName.trim(),
      pubkeyB64: base64Encode(pub),
      deviceId: '',
      requestId: requestId,
    );
    return true;
  } on Object catch (_) {
    await keys.deleteKey();
    return false;
  }
}
