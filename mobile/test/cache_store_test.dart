// Cache store contracts: valid read, empty cache, corrupt row skipped,
// bounded trim oldest first, and write-through replace.
//
// Fakes only. The database port is a fake in-memory list, so no sqflite
// plugin, no platform channel, and no network run here. Each test names
// the contract it guards.
import 'package:calcar/api/models.dart';
import 'package:calcar/cache/cache_store.dart';
import 'package:calcar/cache/cached_device.dart';
import 'package:calcar/cache/db_port.dart';
import 'package:flutter_test/flutter_test.dart';

Device _device({
  required String deviceId,
  String role = 'computer',
  String displayName = 'WIN-PC',
  bool revoked = false,
  String authorizedBy = 'PH-owner',
}) {
  return Device(
    deviceId: deviceId,
    role: role,
    displayName: displayName,
    pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    fingerprint: 'A91C 7D24',
    revoked: revoked,
    authorizedBy: authorizedBy,
  );
}

CachedDevice _cached(String deviceId, int stamp) {
  return CachedDevice(
    deviceId: deviceId,
    displayName: 'PC $deviceId',
    role: 'computer',
    fingerprint: 'A91C 7D24',
    revoked: false,
    authorizedBy: 'PH-owner',
    cachedAtMillis: stamp,
  );
}

class _FakeCacheDb implements CacheDbPort {
  List<Map<String, Object?>> backing = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readDeviceRows() async {
    final List<Map<String, Object?>> out = backing
        .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
        .toList();
    out.sort((Map<String, Object?> a, Map<String, Object?> b) {
      final Object? firstRaw = a[colCachedAtMillis];
      final Object? secondRaw = b[colCachedAtMillis];
      final int first = firstRaw is int ? firstRaw : 0;
      final int second = secondRaw is int ? secondRaw : 0;
      return first.compareTo(second);
    });
    return out;
  }

  @override
  Future<void> replaceDeviceRows(List<Map<String, Object?>> rows) async {
    backing = rows
        .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
        .toList();
  }

  @override
  Future<void> close() async {}
}

CacheStore _store(_FakeCacheDb db) {
  return CacheStore(db: db);
}

void main() {
  group('cache store reads', () {
    test('contract: valid read returns rows and the probe shape', () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = _store(db);
      await store.replaceAll(
        <Device>[
          _device(deviceId: 'PC-1'),
          _device(deviceId: 'PC-2'),
        ],
        nowMillis: 1700000000000,
      );

      final CachedSnapshot snap = await store.readCache();

      expect(snap.rows.length, 2);
      expect(snap.deviceRows, 2);
      expect(snap.isEmpty, isFalse);
      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-1', 'PC-2'],
      );
      expect(snap.rows.first.cachedAtMillis, 1700000000000);
    });

    test('contract: empty cache reads empty', () async {
      final CacheStore store = _store(_FakeCacheDb());

      final CachedSnapshot snap = await store.readCache();

      expect(snap.rows, isEmpty);
      expect(snap.deviceRows, 0);
      expect(snap.isEmpty, isTrue);
    });

    test('contract: corrupt row skipped', () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = _store(db);
      await store.replaceCached(
        <CachedDevice>[_cached('PC-1', 1000)],
      );
      db.backing.add(
        <String, Object?>{colDisplayName: 'orphan without an id'},
      );
      db.backing.add(
        <String, Object?>{colDeviceId: '', colDisplayName: 'blank id'},
      );

      final CachedSnapshot snap = await store.readCache();

      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-1'],
      );
      expect(snap.deviceRows, 1);
    });

    test('contract: revoked and authorized_by survive the round trip',
        () async {
      final CacheStore store = _store(_FakeCacheDb());
      await store.replaceAll(
        <Device>[
          _device(
            deviceId: 'PC-9',
            role: 'computer',
            displayName: 'LAB-PC',
            revoked: true,
            authorizedBy: 'PH-owner',
          ),
        ],
        nowMillis: 1700000000000,
      );

      final CachedSnapshot snap = await store.readCache();

      expect(snap.rows.single.revoked, isTrue);
      expect(snap.rows.single.authorizedBy, 'PH-owner');
      expect(snap.rows.single.role, 'computer');
      expect(snap.rows.single.displayName, 'LAB-PC');
      expect(snap.rows.single.fingerprint, 'A91C 7D24');
    });
  });

  group('cache store writes', () {
    test('contract: replaceAll overwrites the previous snapshot', () async {
      final CacheStore store = _store(_FakeCacheDb());
      await store.replaceAll(
        <Device>[
          _device(deviceId: 'PC-1'),
          _device(deviceId: 'PC-2'),
        ],
        nowMillis: 1000,
      );
      await store.replaceAll(
        <Device>[_device(deviceId: 'PC-3')],
        nowMillis: 2000,
      );

      final CachedSnapshot snap = await store.readCache();

      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-3'],
      );
    });

    test('contract: trim keeps the newest 200 rows, oldest first', () async {
      final CacheStore store = _store(_FakeCacheDb());
      final List<CachedDevice> many = List<CachedDevice>.generate(
        250,
        (int index) => _cached('PC-$index', 1000 + index),
      );
      await store.replaceCached(many);

      final CachedSnapshot snap = await store.readCache();

      expect(snap.rows.length, CacheStore.maxRows);
      expect(snap.deviceRows, 200);
      expect(snap.rows.first.deviceId, 'PC-50');
      expect(snap.rows.first.cachedAtMillis, 1050);
      expect(snap.rows.last.deviceId, 'PC-249');
      expect(snap.rows.last.cachedAtMillis, 1249);
    });

    test('contract: exactly 200 rows keep everything', () async {
      final CacheStore store = _store(_FakeCacheDb());
      final List<CachedDevice> many = List<CachedDevice>.generate(
        200,
        (int index) => _cached('PC-$index', 1000 + index),
      );
      await store.replaceCached(many);

      final CachedSnapshot snap = await store.readCache();

      expect(snap.rows.length, 200);
      expect(snap.rows.first.deviceId, 'PC-0');
      expect(snap.rows.last.deviceId, 'PC-199');
    });
  });
}
