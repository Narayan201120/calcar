// Owner approve signer. Turns the join the card showed into the
// fields the decision endpoint verifies: the subject device id derived
// from the join key, the context hash over exactly what the Owner saw,
// and an Ed25519 signature over the deterministic record bytes.
//
// The byte layouts mirror backend/trust byte for byte and are pinned
// against backend/trust/testdata/vectors.json in tests. Any drift
// fails the grant server side, so this file changes only with the
// proto contract.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:calcar/screens/wired/add_computer_controller.dart';

/// Session TTL the context proxy derives from. Matches trust.PairingTTL:
// the phone reuses expires_at minus this as the join time, exactly like
// the backend requestedAtProxy, since the seam carries no join timestamp.
const int kPairingTtlMillis = 10 * 60 * 1000;

/// Derives the routing id for a computer key: RD-WIN- plus 8 uppercase
/// hex chars from the first 4 bytes of SHA-256. Identifies only, never
/// authenticates. Throws ArgumentError on anything but 32 bytes.
String deviceIDForComputer(List<int> pubkey) {
  if (pubkey.length != 32) {
    throw ArgumentError('Ed25519 public key must be 32 bytes');
  }
  final List<int> sum = crypto.sha256.convert(pubkey).bytes;
  final String hexed = sum
      .sublist(0, 4)
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return 'RD-WIN-$hexed';
}

/// Binds the human context the Owner saw: display name, fingerprint,
/// subject device id, session id, and decimal millis, joined with 0x00
/// and hashed with SHA-256.
Uint8List pairingContextHash({
  required String displayName,
  required String fingerprint,
  required String subjectDeviceId,
  required String sessionId,
  required int requestedAtMillis,
}) {
  final List<int> body = <int>[];
  for (final String field in <String>[
    displayName,
    fingerprint,
    subjectDeviceId,
    sessionId,
    requestedAtMillis.toString(),
  ]) {
    body.addAll(utf8.encode(field));
    body.add(0);
  }
  return Uint8List.fromList(crypto.sha256.convert(body).bytes);
}

void _field(BytesBuilder out, int field, List<int> value) {
  int tag = (field << 3) | 2;
  out.add(_varint(tag));
  out.add(_varint(value.length));
  out.add(value);
}

List<int> _varint(int value) {
  int rest = value;
  final List<int> out = <int>[];
  while (rest >= 0x80) {
    out.add((rest & 0x7F) | 0x80);
    rest >>= 7;
  }
  out.add(rest);
  return out;
}

/// Deterministic record bytes: fields in number order, signature field
/// 7 empty. Must equal trust.SigningPayload output or verification
/// fails. Throws ArgumentError on blank strings or bad key lengths.
Uint8List encodeAuthorizationRecord({
  required String authorizationId,
  required String sessionId,
  required String subjectDeviceId,
  required List<int> subjectPublicKey,
  required String ownerDeviceId,
  required List<int> contextHash,
  required int decidedAtMillis,
  required List<int> nonce,
}) {
  if (authorizationId.isEmpty ||
      sessionId.isEmpty ||
      subjectDeviceId.isEmpty ||
      ownerDeviceId.isEmpty) {
    throw ArgumentError('record string fields must all be non-empty');
  }
  if (subjectPublicKey.length != 32) {
    throw ArgumentError('subject public key must be 32 bytes');
  }
  if (contextHash.isEmpty || nonce.isEmpty || decidedAtMillis <= 0) {
    throw ArgumentError('record hash, nonce, and decided_at are required');
  }
  final BytesBuilder out = BytesBuilder();
  _field(out, 1, utf8.encode(authorizationId));
  _field(out, 2, utf8.encode(sessionId));
  final BytesBuilder subject = BytesBuilder();
  _field(subject, 1, utf8.encode(subjectDeviceId));
  _field(out, 3, subject.takeBytes());
  _field(out, 4, subjectPublicKey);
  final BytesBuilder owner = BytesBuilder();
  _field(owner, 1, utf8.encode(ownerDeviceId));
  _field(out, 5, owner.takeBytes());
  _field(out, 6, contextHash);
  out.add(_varint((8 << 3) | 0));
  out.add(_varint(decidedAtMillis));
  _field(out, 9, nonce);
  return out.takeBytes();
}

/// Signs approvals with the Owner key after a fresh biometric unlock.
/// Matches the PairingSigner shape the controller already calls.
class OwnerPairingSigner {
  OwnerPairingSigner({
    required OwnerKeyService keys,
    required LocalAuthGate gate,
    String Function()? authorizationId,
    List<int> Function()? nonceBytes,
    int Function()? nowMillis,
  })  : _keys = keys,
        _gate = gate,
        _authorizationId =
            authorizationId ?? _defaultAuthorizationId,
        _nonceBytes = nonceBytes ?? _defaultNonceBytes,
        _nowMillis =
            nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final OwnerKeyService _keys;
  final LocalAuthGate _gate;
  final String Function() _authorizationId;
  final List<int> Function() _nonceBytes;
  final int Function() _nowMillis;

  Future<PairingAuthorization> call(PairingJoin join) async {
    if (join.pubkeyB64.isEmpty ||
        join.sessionId.isEmpty ||
        join.ownerDeviceId.isEmpty ||
        join.requestedAtMillis <= 0) {
      throw StateError('join is missing the bindings approval needs');
    }
    final LocalAuthResult auth = await _gate.authenticate(
      reason: 'Approve ${join.displayName}',
    );
    if (auth != LocalAuthResult.unlocked) {
      throw StateError('approval refused at re-auth');
    }
    final List<int> pub = base64Decode(join.pubkeyB64);
    final String subjectDeviceId = deviceIDForComputer(pub);
    final Uint8List context = pairingContextHash(
      displayName: join.displayName,
      fingerprint: join.fingerprint,
      subjectDeviceId: subjectDeviceId,
      sessionId: join.sessionId,
      requestedAtMillis: join.requestedAtMillis,
    );
    final int decidedAt = _nowMillis();
    final String authId = _authorizationId();
    final List<int> nonce = _nonceBytes();
    final Uint8List payload = encodeAuthorizationRecord(
      authorizationId: authId,
      sessionId: join.sessionId,
      subjectDeviceId: subjectDeviceId,
      subjectPublicKey: pub,
      ownerDeviceId: join.ownerDeviceId,
      contextHash: context,
      decidedAtMillis: decidedAt,
      nonce: nonce,
    );
    final Uint8List sig = await _keys.sign(payload);
    return PairingAuthorization(
      signatureB64: base64Encode(sig),
      authorizationId: authId,
      nonceB64: base64Encode(nonce),
      decidedAtMillis: decidedAt,
    );
  }

  static String _defaultAuthorizationId() {
    final Random random = Random.secure();
    final List<int> raw =
        List<int>.generate(16, (_) => random.nextInt(256));
    return raw.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _defaultNonceBytes() {
    final Random random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256));
  }
}
