import 'dart:convert';
import 'dart:typed_data';

import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/pairing/approve_signer.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:calcar/screens/wired/add_computer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixed vectors from backend/trust/testdata/vectors.json. The phone must
// produce byte-identical values or the backend rejects the grant.
const String _computerPubHex =
    '29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7';
const String _computerFingerprint =
    '24F6 ED6A CBFE 1009 C030 D7CA 567C 33CA 4830 9114 9823 6B55 61A6 C82A BEC5 DE28';
const String _contextHex =
    '80b689d778bba1d2de74aee5f10034d964ab5c437b3faabdf19a228dd98d8da9';
const String _payloadHex =
    '0a10617574682d766563746f722d303030311210736573732d766563746f722d30303031'
    '1a110a0f52442d57494e2d3234463645443641222029acbae141bccaf0b22e1a94d34d0bc73'
    '61e526d0bfe12c89794bc9322966dd72a170a156f776e65722d70686f6e652d766563746f72'
    '2d3031322080b689d778bba1d2de74aee5f10034d964ab5c437b3faabdf19a228dd98d8da94'
    '080b0c08e8b344a100102030405060708090a0b0c0d0e0f10';
const String _ownerSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String _ownerSigHex =
    'd226b23b9af1c3b33de248961e8929a6bad57b156bef60f48bf1c86fb11587e48a7b8480205'
    '12bce386b90ca726d47b4bc3aff962df76456382179edb12cfd00';

Uint8List _hex(String hexed) {
  final List<int> out = <int>[];
  for (int i = 0; i < hexed.length; i += 2) {
    out.add(int.parse(hexed.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(out);
}

class _MapStore implements SeedStore {
  final Map<String, String> backing = <String, String>{};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async {
    backing[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    backing.remove(key);
  }
}

class _Gate implements LocalAuthGate {
  _Gate(this.result);

  final LocalAuthResult result;

  @override
  Future<LocalAuthResult> authenticate({required String reason}) async {
    return result;
  }
}

void main() {
  group('approve vectors', () {
    test(
      'contract: computer device id matches the backend byte for byte',
      () {
        expect(
          deviceIDForComputer(_hex(_computerPubHex)),
          'RD-WIN-24F6ED6A',
        );
      },
    );

    test(
      'contract: non 32-byte input is refused, never formatted',
      () {
        expect(() => deviceIDForComputer(<int>[1, 2, 3]), throwsArgumentError);
      },
    );

    test(
      'contract: context hash matches the backend byte for byte',
      () {
        expect(
          pairingContextHash(
            displayName: 'Narayan-PC',
            fingerprint: _computerFingerprint,
            subjectDeviceId: 'RD-WIN-24F6ED6A',
            sessionId: 'sess-vector-0001',
            requestedAtMillis: 1789689300000,
          ),
          _hex(_contextHex),
        );
      },
    );

    test(
      'contract: record bytes match SigningPayload byte for byte',
      () {
        expect(
          encodeAuthorizationRecord(
            authorizationId: 'auth-vector-0001',
            sessionId: 'sess-vector-0001',
            subjectDeviceId: 'RD-WIN-24F6ED6A',
            subjectPublicKey: _hex(_computerPubHex),
            ownerDeviceId: 'owner-phone-vector-01',
            contextHash: _hex(_contextHex),
            decidedAtMillis: 1789689600000,
            nonce: _hex('0102030405060708090a0b0c0d0e0f10'),
          ),
          _hex(_payloadHex),
        );
      },
    );

    test(
      'contract: the Owner key signs the vector payload to the vector signature',
      () async {
        final _MapStore store = _MapStore();
        store.backing[OwnerKeyService.seedKey] =
            base64Encode(_hex(_ownerSeedHex));
        final OwnerKeyService keys = OwnerKeyService(store: store);
        final Uint8List sig = await keys.sign(_hex(_payloadHex));
        expect(base64Encode(sig), base64Encode(_hex(_ownerSigHex)));
      },
    );
  });

  group('owner signer', () {
    PairingJoin makeJoin() {
      return PairingJoin(
        requestId: 'req-1',
        pubkeyB64: base64Encode(_hex(_computerPubHex)),
        displayName: 'Narayan-PC',
        fingerprint: _computerFingerprint,
        sessionId: 'sess-vector-0001',
        ownerDeviceId: 'owner-phone-vector-01',
        requestedAtMillis: 1789689300000,
      );
    }

    OwnerKeyService makeKeys() {
      final _MapStore store = _MapStore();
      store.backing[OwnerKeyService.seedKey] =
          base64Encode(_hex(_ownerSeedHex));
      return OwnerKeyService(store: store);
    }

    test(
      'contract: unlock plus sign returns fields bound to this join',
      () async {
        final OwnerPairingSigner signer = OwnerPairingSigner(
          keys: makeKeys(),
          gate: _Gate(LocalAuthResult.unlocked),
          authorizationId: () => 'auth-vector-0001',
          nonceBytes: () => _hex('0102030405060708090a0b0c0d0e0f10'),
          nowMillis: () => 1789689600000,
        );
        final PairingAuthorization auth = await signer(makeJoin());
        expect(auth.authorizationId, 'auth-vector-0001');
        expect(auth.decidedAtMillis, 1789689600000);
        expect(
          base64Decode(auth.signatureB64),
          base64Decode(base64Encode(_hex(_ownerSigHex))),
        );
      },
    );

    test(
      'contract: refused re-auth signs nothing and reports failure',
      () async {
        final OwnerPairingSigner signer = OwnerPairingSigner(
          keys: makeKeys(),
          gate: _Gate(LocalAuthResult.cancelled),
        );
        expect(() => signer(makeJoin()), throwsStateError);
      },
    );

    test(
      'contract: a join missing bindings is refused before any signing',
      () async {
        final OwnerPairingSigner signer = OwnerPairingSigner(
          keys: makeKeys(),
          gate: _Gate(LocalAuthResult.unlocked),
        );
        const PairingJoin bare = PairingJoin(
          requestId: 'req-1',
          pubkeyB64: '',
          displayName: 'Narayan-PC',
          fingerprint: 'FP',
        );
        expect(() => signer(bare), throwsStateError);
      },
    );
  });
}
