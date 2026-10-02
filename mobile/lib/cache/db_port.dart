// Tiny seam between the cache store and SQLite.
//
// [CacheStore] talks only to this port, so unit tests run behind a fake
// in-memory map and never touch the real sqflite plugin. The real
// implementation lives in sqflite_cache_db.dart and is the only file
// that imports sqflite.
library;

/// Row transport for the devices table. Maps use the column names from
/// cached_device.dart. Reads come back oldest first.
abstract class CacheDbPort {
  /// All device rows, oldest first.
  Future<List<Map<String, Object?>>> readDeviceRows();

  /// Replaces the whole table with [rows] in one batch.
  Future<void> replaceDeviceRows(List<Map<String, Object?>> rows);

  /// Closes the database.
  Future<void> close();
}
