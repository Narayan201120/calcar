// SQLite cache store: one file, one devices table, bounded rows.
//
// Owns the snapshot the cold start paints before any network call. Writes
// replace the whole table in one batch and the trim keeps the newest
// [maxRows] rows, oldest first, so the cache cannot grow without bound.
// Reads skip corrupt rows instead of failing the boot.
//
// Pure Dart plus the [CacheDbPort] seam. No network, no platform channel
// of its own: the sqflite file behind the port owns the only channel.
library;

import 'package:calcar/api/models.dart';

import 'cached_device.dart';
import 'db_port.dart';

/// What a cold start learns from the cache: the rows for seeding plus a
/// [CacheProbe]-compatible shape ([deviceRows], [isEmpty]) for the gate
/// strip. Kept separate from app.dart so this file stays pure Dart; the
/// adapter in cache_source.dart converts it to the real [CacheProbe].
class CachedSnapshot {
  final List<CachedDevice> rows;

  const CachedSnapshot(this.rows);

  const CachedSnapshot.empty() : rows = const <CachedDevice>[];

  /// Row count, the same number the gate paints in its strip.
  int get deviceRows => rows.length;

  bool get isEmpty => rows.isEmpty;
}

/// Owns one SQLite devices table behind a [CacheDbPort].
class CacheStore {
  CacheStore({required CacheDbPort db}) : dbPort = db;

  /// Row cap. Oldest rows go first once the snapshot passes it.
  static const int maxRows = 200;

  final CacheDbPort dbPort;

  /// Reads the cached snapshot. Corrupt rows are skipped, so one bad row
  /// never blanks the cached frame.
  Future<CachedSnapshot> readCache() async {
    final List<Map<String, Object?>> raw = await dbPort.readDeviceRows();
    final List<CachedDevice> rows = <CachedDevice>[];
    for (final Map<String, Object?> row in raw) {
      final CachedDevice? device = CachedDevice.fromMap(row);
      if (device != null) {
        rows.add(device);
      }
    }
    return CachedSnapshot(List<CachedDevice>.unmodifiable(rows));
  }

  /// Write-through replace for a snapshot fetch: the whole list swaps in
  /// under one stamp, then the trim keeps the newest [maxRows].
  Future<void> replaceAll(List<Device> devices, {int? nowMillis}) async {
    final int stamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final List<CachedDevice> mapped = devices
        .map(
          (Device device) => CachedDevice.fromDevice(
            device,
            cachedAtMillis: stamp,
          ),
        )
        .toList(growable: false);
    await replaceCached(mapped);
  }

  /// Replaces the table with pre-stamped rows. Tests use this to pin
  /// distinct stamps per row and prove oldest-first eviction.
  Future<void> replaceCached(List<CachedDevice> devices) async {
    final List<CachedDevice> ordered = List<CachedDevice>.from(devices);
    ordered.sort(
      (CachedDevice a, CachedDevice b) =>
          a.cachedAtMillis.compareTo(b.cachedAtMillis),
    );
    final List<CachedDevice> capped = ordered.length <= maxRows
        ? ordered
        : ordered.sublist(ordered.length - maxRows);
    final List<Map<String, Object?>> rows = capped
        .map((CachedDevice device) => device.toMap())
        .toList(growable: false);
    await dbPort.replaceDeviceRows(rows);
  }

  Future<void> close() => dbPort.close();
}
