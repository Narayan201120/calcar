// APK download plus SHA-256 gate. The file lands in app-controlled
// temporary storage, old staged APKs are swept, and the checksum runs
// before anything else may use the path. A mismatch deletes the file
// so a tampered download can never reach the installer.
library;

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Lowercase hex SHA-256 of bytes. Pure, fully tested.
String sha256Hex(List<int> bytes) {
  return crypto.sha256.convert(bytes).toString();
}

/// Where staged APKs live. Seamed so tests use a throwaway temp dir
/// instead of the platform channel.
typedef DirectoryProvider = Future<Directory> Function();

Future<Directory> defaultDirectoryProvider() {
  return getTemporaryDirectory();
}

bool _isStaleApk(String path) {
  final String name = path.split(Platform.pathSeparator).last;
  return name.startsWith('calcar-update-') && name.endsWith('.apk');
}

/// Downloads one release APK. Throws StateError on HTTP errors and on
/// empty bodies, which read as corrupt rather than as zero-byte installs.
Future<File> downloadApk({
  required String apkUrl,
  required int versionCode,
  http.Client? client,
  DirectoryProvider directoryProvider = defaultDirectoryProvider,
}) async {
  final http.Client owned = client ?? http.Client();
  try {
    final http.Response response =
        await owned.get(Uri.parse(apkUrl));
    if (response.statusCode != 200) {
      throw StateError(
        'APK download failed: HTTP ${response.statusCode}',
      );
    }
    if (response.bodyBytes.isEmpty) {
      throw const StateError('downloaded APK is empty');
    }
    final Directory dir = await directoryProvider();
    for (final FileSystemEntity entry in dir.listSync()) {
      if (entry is File && _isStaleApk(entry.path)) {
        try {
          entry.deleteSync();
        } on Object {
          // A stale file that cannot be deleted is harmless: the new
          // file name is unique per versionCode.
        }
      }
    }
    final File out = File(
      '${dir.path}${Platform.pathSeparator}calcar-update-$versionCode.apk',
    );
    await out.writeAsBytes(response.bodyBytes, flush: true);
    return out;
  } finally {
    if (client == null) {
      owned.close();
    }
  }
}

/// Compares the staged file against the manifest hash. Throws StateError
/// on missing, empty, or mismatched files. The caller deletes the file
/// on mismatch so it can never be installed later by accident.
Future<void> verifyApkSha256(File apk, String expectedSha256) async {
  if (!apk.existsSync()) {
    throw const StateError('staged APK is missing');
  }
  final List<int> bytes = await apk.readAsBytes();
  if (bytes.isEmpty) {
    throw const StateError('staged APK is empty or corrupt');
  }
  final String actual = sha256Hex(bytes);
  if (actual != expectedSha256.toLowerCase()) {
    throw StateError(
      'checksum mismatch: expected $expectedSha256, got $actual',
    );
  }
}
