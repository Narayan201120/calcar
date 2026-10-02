// Real SQLite port behind sqflite. The only file that imports sqflite.
//
// Schema: one devices table keyed by device_id, holding the last
// foreground snapshot plus the write stamp. Opens with
// [SqfliteCacheDb.open], which takes an injectable path and open
// function so tests can pass a fake and never touch this file.
library;

import 'package:sqflite/sqflite.dart';

import 'cached_device.dart';
import 'db_port.dart';

/// Injectable open matching sqflite's openDatabase for the two arguments
/// this file uses. Tests pass a stub; production passes nothing and gets
/// the real openDatabase through [_openDefault].
typedef CacheOpenFn = Future<Database> Function(
  String path, {
  int? version,
  Future<void> Function(Database, int)? onCreate,
});

/// Creates the devices table. Runs once per database file.
Future<void> createCacheSchema(Database db, int version) async {
  await db.execute(
    'CREATE TABLE IF NOT EXISTS $cacheDevicesTable ('
    '$colDeviceId TEXT PRIMARY KEY, '
    '$colDisplayName TEXT NOT NULL, '
    '$colRole TEXT NOT NULL, '
    '$colFingerprint TEXT NOT NULL, '
    '$colRevoked INTEGER NOT NULL, '
    '$colAuthorizedBy TEXT NOT NULL, '
    '$colCachedAtMillis INTEGER NOT NULL)',
  );
}

/// Default open: the real sqflite openDatabase with the cache schema.
Future<Database> _openDefault(
  String path, {
  int? version,
  Future<void> Function(Database, int)? onCreate,
}) {
  return openDatabase(
    path,
    version: version,
    onCreate: onCreate,
  );
}

/// Sqflite implementation of [CacheDbPort].
class SqfliteCacheDb implements CacheDbPort {
  SqfliteCacheDb._(this.database);

  final Database database;

  /// Opens (or creates) the cache file. [dbPath] defaults to
  /// calcar_cache.db inside the sqflite databases directory; [openFn]
  /// defaults to the real openDatabase and exists so tests can inject
  /// a stub without the plugin.
  static Future<SqfliteCacheDb> open({
    String? dbPath,
    CacheOpenFn? openFn,
  }) async {
    final CacheOpenFn opener = openFn ?? _openDefault;
    final String base = await getDatabasesPath();
    final String resolved = dbPath ?? '$base/calcar_cache.db';
    final Database database = await opener(
      resolved,
      version: 1,
      onCreate: createCacheSchema,
    );
    return SqfliteCacheDb._(database);
  }

  @override
  Future<List<Map<String, Object?>>> readDeviceRows() {
    return database.query(
      cacheDevicesTable,
      orderBy: '$colCachedAtMillis ASC',
    );
  }

  @override
  Future<void> replaceDeviceRows(List<Map<String, Object?>> rows) async {
    final Batch batch = database.batch();
    batch.delete(cacheDevicesTable);
    for (final Map<String, Object?> row in rows) {
      batch.insert(
        cacheDevicesTable,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> close() => database.close();
}
