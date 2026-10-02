// Cache adapter contracts: the cold start probe plus seeding rows, and
// write-through replace on snapshot fetch.
//
// Fakes only. The database port is a fake in-memory list and the snapshot
// source is canned data, so no sqflite plugin, no platform channel, and
// no network run here. Each test names the contract it guards.
import 'package:calcar/api/models.dart';
import 'package:calcar/app.dart';
import 'package:calcar/cache/cache_source.dart';
import 'package:calcar/cache/cache_store.dart';
import 'package:calcar/cache/cached_device.dart';
import 'package:calcar/cache/db_port.dart';
import 'package:calcar/state/models.dart';
import 'package:calcar/state/snapshot_source.dart';
import 'package:flutter_test/flutter_test.dart';

Device _device(String deviceId) {
  return Device(
    deviceId: deviceId,
    role: 'computer',
    displayName: 'PC $deviceId',
    pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    fingerprint: 'A91C 7D24',
    revoked: false,
    authorizedBy: 'PH-owner',
  );
}

class _FakeCacheDb implements CacheDbPort {
  List<Map<String, Object?>> backing = <Map<String, Object?>>[];
  bool failReads = false;

  @override
  Future<List<Map<String, Object?>>> readDeviceRows() async {
    if (failReads) {
      throw StateError('db read failed');
    }
    return backing
        .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
        .toList();
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

class _FakeSnapshotSource implements SnapshotSource {
  List<Device> devices = <Device>[
    _device('PC-1'),
    _device('PC-2'),
  ];
  bool failDevices = false;

  @override
  Future<List<Device>> fetchDevices() {
    if (failDevices) {
      return Future<List<Device>>.error(StateError('network down'));
    }
    return Future<List<Device>>.value(List<Device>.from(devices));
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    return Future<Map<String, Presence>>.value(
      const <String, Presence>{},
    );
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return Future<String>.value('PH-owner');
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    return Future<ComputerSnapshot>.value(
      ComputerSnapshot(
        deviceId: computerId,
        displayName: 'WIN-PC',
        online: true,
        lastSeenMillis: 1700000000000,
        workflows: const <WorkflowRow>[],
      ),
    );
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    return Future<WorkflowBuffers>.value(
      WorkflowBuffers.empty(
        computerId: computerId,
        workflowId: workflowId,
      ),
    );
  }
}

void main() {
  group('cold start from the cache', () {
    test('contract: cold start source returns the cached row count',
        () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = CacheStore(db: db);
      await store.replaceAll(
        <Device>[_device('PC-1'), _device('PC-2')],
        nowMillis: 1700000000000,
      );
      final CacheBackedColdStartSource source =
          CacheBackedColdStartSource(store: store);

      final CacheProbe probe = await source.readCache();

      expect(probe.deviceRows, 2);
      expect(probe.isEmpty, isFalse);
    });

    test('contract: cold start source returns empty when cache is empty',
        () async {
      final CacheBackedColdStartSource source = CacheBackedColdStartSource(
        store: CacheStore(db: _FakeCacheDb()),
      );

      final CacheProbe probe = await source.readCache();

      expect(probe.deviceRows, 0);
      expect(probe.isEmpty, isTrue);
    });

    test('contract: cold start source returns empty when database fails',
        () async {
      final _FakeCacheDb db = _FakeCacheDb()..failReads = true;
      final CacheBackedColdStartSource source = CacheBackedColdStartSource(
        store: CacheStore(db: db),
      );

      final CacheProbe probe = await source.readCache();

      expect(probe.deviceRows, 0);
      expect(probe.isEmpty, isTrue);
    });

    test('contract: seed rows carry the full cached devices', () async {
      final CacheStore store = CacheStore(db: _FakeCacheDb());
      await store.replaceAll(
        <Device>[_device('PC-1'), _device('PC-7')],
        nowMillis: 1700000000000,
      );
      final CacheBackedColdStartSource source =
          CacheBackedColdStartSource(store: store);

      final List<CachedDevice> rows = await source.readSeedRows();

      expect(
        rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-1', 'PC-7'],
      );
      expect(rows.first.displayName, 'PC PC-1');
      expect(rows.first.role, 'computer');
    });
  });

  group('write-through on snapshot fetch', () {
    test('contract: write-through replaces the cache on snapshot fetch',
        () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = CacheStore(db: db);
      await store.replaceAll(
        <Device>[_device('PC-old')],
        nowMillis: 1000,
      );
      final _FakeSnapshotSource inner = _FakeSnapshotSource()
        ..devices = <Device>[_device('PC-1'), _device('PC-2')];
      final WriteThroughSnapshotSource source =
          WriteThroughSnapshotSource(inner: inner, store: store);

      final List<Device> devices = await source.fetchDevices();
      final CachedSnapshot snap = await store.readCache();

      expect(
        devices.map((Device device) => device.deviceId).toList(),
        <String>['PC-1', 'PC-2'],
      );
      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-1', 'PC-2'],
      );
    });

    test('contract: write-through keeps the old cache when fetch fails',
        () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = CacheStore(db: db);
      await store.replaceAll(
        <Device>[_device('PC-old')],
        nowMillis: 1000,
      );
      final _FakeSnapshotSource inner = _FakeSnapshotSource()
        ..failDevices = true;
      final WriteThroughSnapshotSource source =
          WriteThroughSnapshotSource(inner: inner, store: store);

      await expectLater(source.fetchDevices(), throwsStateError);
      final CachedSnapshot snap = await store.readCache();

      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-old'],
      );
    });

    test(
        'contract: non-device fetches delegate without touching the cache',
        () async {
      final _FakeCacheDb db = _FakeCacheDb();
      final CacheStore store = CacheStore(db: db);
      await store.replaceAll(
        <Device>[_device('PC-old')],
        nowMillis: 1000,
      );
      final WriteThroughSnapshotSource source = WriteThroughSnapshotSource(
        inner: _FakeSnapshotSource(),
        store: store,
      );

      final Map<String, Presence> presence = await source.fetchPresence();
      final String ownerId = await source.fetchOwnerDeviceId();
      final ComputerSnapshot computer = await source.fetchComputer('PC-1');
      final WorkflowBuffers buffers = await source.fetchWorkflow(
        'PC-1',
        'wf-1',
      );
      final CachedSnapshot snap = await store.readCache();

      expect(presence, isEmpty);
      expect(ownerId, 'PH-owner');
      expect(computer.deviceId, 'PC-1');
      expect(buffers.workflowId, 'wf-1');
      expect(
        snap.rows.map((CachedDevice row) => row.deviceId).toList(),
        <String>['PC-old'],
      );
    });
  });
}
