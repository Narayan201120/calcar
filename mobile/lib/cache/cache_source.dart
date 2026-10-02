// Cache adapters: cold start reads and write-through snapshot fetches.
//
// [CacheBackedColdStartSource] is the override for coldStartSourceProvider:
// it turns the cached rows into the [CacheProbe] the gate paints, and a
// broken database reads as an empty cache instead of a failed boot.
// [WriteThroughSnapshotSource] wraps the live snapshot source so every
// device fetch replaces the cache; every other fetch delegates untouched.
// No network here, no platform channel: both classes only call the store
// and the wrapped source.
library;

import 'package:calcar/api/models.dart';
import 'package:calcar/app.dart';
import 'package:calcar/state/models.dart';
import 'package:calcar/state/snapshot_source.dart';

import 'cache_store.dart';
import 'cached_device.dart';

/// SQLite backed reader for the cold start gate.
class CacheBackedColdStartSource implements ColdStartSource {
  CacheBackedColdStartSource({required this.store});

  final CacheStore store;

  @override
  Future<CacheProbe> readCache() async {
    try {
      final CachedSnapshot snap = await store.readCache();
      return CacheProbe(snap.deviceRows);
    } on Object {
      return const CacheProbe.empty();
    }
  }

  /// Full cached rows for seeding the device list behind the gate strip.
  /// Corrupt rows are already skipped by the store.
  Future<List<CachedDevice>> readSeedRows() async {
    try {
      final CachedSnapshot snap = await store.readCache();
      return snap.rows;
    } on Object {
      return const <CachedDevice>[];
    }
  }
}

/// Snapshot source that replaces the device cache on every device fetch.
/// Presence, Owner id, computer, and workflow fetches delegate to [inner]
/// without touching the cache.
class WriteThroughSnapshotSource implements SnapshotSource {
  WriteThroughSnapshotSource({required this.inner, required this.store});

  final SnapshotSource inner;
  final CacheStore store;

  @override
  Future<List<Device>> fetchDevices() async {
    final List<Device> devices = await inner.fetchDevices();
    await store.replaceAll(devices);
    return devices;
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    return inner.fetchPresence();
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return inner.fetchOwnerDeviceId();
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    return inner.fetchComputer(computerId);
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    return inner.fetchWorkflow(computerId, workflowId);
  }
}
