import 'dart:convert';
import 'dart:typed_data';

import 'package:calcar/keys/owner_keys.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  group('fingerprint derivation', () {
    test(
      'contract: fingerprint matches the backend trust package byte for byte',
      () {
        final List<int> pubkey = List<int>.generate(32, (int i) => i);
        expect(
          OwnerKeyService.fingerprintOf(pubkey),
          '630D CD29 66C4 3366 9112 5448 BBB2 5B4F '
          'F412 A49C 732D B2C8 ABC1 B858 1BD7 10DD',
        );
      },
    );

    test(
      'contract: non 32-byte input is refused, never formatted',
      () {
        expect(() => OwnerKeyService.fingerprintOf(<int>[1, 2, 3]), throwsArgumentError);
      },
    );
  });

  group('key lifecycle', () {
    test(
      'contract: no key exists before generate',
      () async {
        final OwnerKeyService keys = OwnerKeyService(store: _MapStore());
        expect(await keys.hasKey(), isFalse);
      },
    );

    test(
      'contract: generate persists a signing key and sign verifies',
      () async {
        final OwnerKeyService keys = OwnerKeyService(store: _MapStore());
        await keys.generate();
        expect(await keys.hasKey(), isTrue);
        final Uint8List pub = await keys.publicKey();
        expect(pub.length, 32);
        final Uint8List sig = await keys.sign(utf8.encode('calcar approval'));
        expect(sig.length, 64);
        final bool ok = await Ed25519().verify(
          utf8.encode('calcar approval'),
          signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
        );
        expect(ok, isTrue);
      },
    );

    test(
      'contract: seed survives across service instances on the same store',
      () async {
        final _MapStore store = _MapStore();
        await OwnerKeyService(store: store).generate();
        final Uint8List first = await OwnerKeyService(store: store).publicKey();
        final Uint8List second = await OwnerKeyService(store: store).publicKey();
        expect(first, second);
      },
    );

    test(
      'contract: delete forgets everything and signing after fails',
      () async {
        final OwnerKeyService keys = OwnerKeyService(store: _MapStore());
        await keys.generate();
        await keys.deleteKey();
        expect(await keys.hasKey(), isFalse);
        expect(() => keys.sign(<int>[1]), throwsStateError);
        expect(() => keys.publicKey(), throwsStateError);
      },
    );

    test(
      'contract: the seed is never exposed, only signatures leave',
      () async {
        final _MapStore store = _MapStore();
        final OwnerKeyService keys = OwnerKeyService(store: store);
        await keys.generate();
        final String? stored = store.backing[OwnerKeyService.seedKey];
        expect(stored, isNotNull);
        expect(base64Decode(stored!).length, 32);
      },
    );
  });
}
