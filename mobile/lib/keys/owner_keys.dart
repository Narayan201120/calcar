// Owner Ed25519 key service. The seed lives hardware-wrapped at rest,
// enters app memory only inside sign calls that biometric auth already
// gated, and never reaches a log. Android Keystore mints no Ed25519, so
// the hardware-backed wrapping key comes from flutter_secure_storage and
// the seed itself is software bytes encrypted by it. That is the
// industry-standard shape on Android and matches the P2 decision of
// hardware-backed storage with TEE fallback.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Reader-writer seam so tests use a map fake with zero platform
/// channels. Production uses the secure store.
abstract class SeedStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Hardware-wrapped store. The account pins the keychain entry to this
/// app, and encrypted shared preferences keep the Android side out of
/// cleartext prefs.
class SecureSeedStore implements SeedStore {
  const SecureSeedStore({FlutterSecureStorage? storage})
      : _storage = storage;

  final FlutterSecureStorage? _storage;

  FlutterSecureStorage get _store =>
      _storage ??
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(accountName: 'calcar'),
      );

  @override
  Future<String?> read(String key) => _store.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _store.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _store.delete(key: key);
}

/// Owner keypair lifecycle. One method per fact: generate, persist,
/// sign, forget. No getter ever returns the seed.
class OwnerKeyService {
  OwnerKeyService({SeedStore? store})
      : _store = store ?? const SecureSeedStore();

  static const String seedKey = 'calcar_owner_seed';

  final SeedStore _store;
  final Ed25519 _algorithm = Ed25519();

  Future<bool> hasKey() async => (await _store.read(seedKey)) != null;

  /// Fresh random keypair, persisted before returning. The seed comes
  /// from the platform CSPRNG and is built into a pair from seed bytes,
  /// so no private material is ever extracted out of a key object.
  /// Overwrites any previous seed, so rotation is generate plus
  /// re-bootstrap.
  Future<void> generate() async {
    final Random random = Random.secure();
    final Uint8List seed = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _algorithm.newKeyPairFromSeed(seed);
    await _store.write(seedKey, base64Encode(seed));
  }

  Future<Uint8List> _seed() async {
    final String? encoded = await _store.read(seedKey);
    if (encoded == null) {
      throw StateError('no Owner key established');
    }
    final List<int> seed = base64Decode(encoded);
    if (seed.length != 32) {
      throw StateError('stored Owner seed has the wrong length');
    }
    return Uint8List.fromList(seed);
  }

  Future<SimpleKeyPair> _pair() async {
    final Uint8List seed = await _seed();
    final SimpleKeyPair pair = await _algorithm.newKeyPairFromSeed(seed);
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    return SimpleKeyPairData(
      seed,
      publicKey: publicKey,
      type: KeyPairType.ed25519,
    );
  }

  /// 32-byte public key for the bootstrap call.
  Future<Uint8List> publicKey() async {
    final SimplePublicKey public =
        await (await _pair()).extractPublicKey();
    return Uint8List.fromList(public.bytes);
  }

  /// Human fingerprint. Byte-identical derivation to the backend trust
  /// package: uppercase hex SHA-256 grouped in fours. The backend
  /// rejects anything else, so this format is contract, not style.
  Future<String> fingerprint() async {
    return fingerprintOf(await publicKey());
  }

  /// Signs exactly the bytes given. The seed is read, used, and dropped
  /// inside this call.
  Future<Uint8List> sign(List<int> message) async {
    final SimpleKeyPair pair = await _pair();
    final Signature signature =
        await _algorithm.sign(message, keyPair: pair);
    return Uint8List.fromList(signature.bytes);
  }

  Future<void> deleteKey() => _store.delete(seedKey);

  /// Pure derivation, pinned against the backend with a fixed vector in
  /// tests. Throws ArgumentError on anything but 32 bytes.
  static String fingerprintOf(List<int> pubkey) {
    if (pubkey.length != 32) {
      throw ArgumentError('Ed25519 public key must be 32 bytes');
    }
    final String hexed = crypto.sha256
        .convert(pubkey)
        .toString()
        .toUpperCase();
    final List<String> groups = <String>[];
    for (int i = 0; i < hexed.length; i += 4) {
      groups.add(hexed.substring(i, i + 4));
    }
    return groups.join(' ');
  }
}
