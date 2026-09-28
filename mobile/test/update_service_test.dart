import 'dart:convert';
import 'dart:io';

import 'package:calcar/update/apk_downloader.dart';
import 'package:calcar/update/apk_installer.dart';
import 'package:calcar/update/update_controller.dart';
import 'package:calcar/update/update_manifest.dart';
import 'package:calcar/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _manifestBody = '''
{
  "latest": {
    "versionCode": 18,
    "versionName": "0.1.0+18",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-18/calcar.apk",
    "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  },
  "previous": {
    "versionCode": 16,
    "versionName": "0.1.0+16",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-16/calcar.apk",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}
''';

/// 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 is the
/// SHA-256 of the ASCII bytes of "test".
final List<int> _apkBytes = utf8.encode('test');

class _FakeInstaller implements ApkInstaller {
  _FakeInstaller(this.result);

  final ApkInstallResult result;
  final List<String> launched = <String>[];

  @override
  Future<ApkInstallResult> install(String apkPath) async {
    launched.add(apkPath);
    return result;
  }
}

UpdateController _controller({
  UpdateManifest? manifest,
  Object? fetchError,
  int currentCode = 16,
  Future<File> Function(UpdateRelease release, DownloadProgress onProgress)?
      download,
  ApkInstaller? installer,
}) {
  return UpdateController(
    fetchManifest: () async {
      if (fetchError != null) {
        throw fetchError;
      }
      return manifest ?? UpdateManifest.parse(_manifestBody);
    },
    readCurrentCode: () async => currentCode,
    downloadApk: download ??
        (UpdateRelease release, DownloadProgress onProgress) async {
          final Directory dir =
              await Directory.systemTemp.createTemp('calcar-update-test');
          final File file = File('${dir.path}/calcar-update.apk');
          await file.writeAsBytes(_apkBytes, flush: true);
          return file;
        },
    installer: installer ??
        _FakeInstaller(const ApkInstallResult(ApkInstallOutcome.opened, 'ok')),
  );
}

void main() {
  group('manifest fetch', () {
    test(
      'contract: HTTP error is a failure, never a manifest',
      () async {
        final http.Client client = MockClient(
          (http.Request request) async => http.Response('nope', 404),
        );
        expect(
          () => fetchUpdateManifest(
            client,
            Uri.parse('https://example.com/update.json'),
          ),
          throwsStateError,
        );
      },
    );

    test(
      'contract: invalid JSON from the server is refused',
      () async {
        final http.Client client = MockClient(
          (http.Request request) async => http.Response('not json', 200),
        );
        expect(
          () => fetchUpdateManifest(
            client,
            Uri.parse('https://example.com/update.json'),
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('checksum', () {
    test(
      'contract: matching bytes verify cleanly',
      () async {
        final Directory dir =
            await Directory.systemTemp.createTemp('calcar-sha-test');
        final File file = File('${dir.path}/a.apk');
        await file.writeAsBytes(_apkBytes, flush: true);
        await verifyApkSha256(
          file,
          '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
        );
      },
    );

    test(
      'contract: mismatched bytes stop before any install',
      () async {
        final Directory dir =
            await Directory.systemTemp.createTemp('calcar-sha-test');
        final File file = File('${dir.path}/a.apk');
        await file.writeAsBytes(_apkBytes, flush: true);
        expect(
          () => verifyApkSha256(
            file,
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
          throwsStateError,
        );
      },
    );

    test(
      'contract: an empty file is corrupt, never installable',
      () async {
        final Directory dir =
            await Directory.systemTemp.createTemp('calcar-sha-test');
        final File file = File('${dir.path}/a.apk');
        await file.writeAsBytes(<int>[], flush: true);
        expect(
          () => verifyApkSha256(
            file,
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          ),
          throwsStateError,
        );
      },
    );

    test(
      'contract: streamed download reports progress and writes the file',
      () async {
        final http.Client client = MockClient(
          (http.Request request) async => http.Response('test', 200),
        );
        final List<String> events = <String>[];
        final Directory dir =
            await Directory.systemTemp.createTemp('calcar-prog-test');
        final File file = await downloadApk(
          apkUrl: 'https://example.com/calcar.apk',
          versionCode: 99,
          client: client,
          directoryProvider: () async => dir,
          onProgress: (int received, int? total) {
            events.add('$received/$total');
          },
        );
        expect(file.existsSync(), isTrue);
        expect(events, isNotEmpty);
        expect(events.last, '4/4');
        await verifyApkSha256(
          file,
          '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
        );
      },
    );
  });

  group('update flow', () {
    test(
      'contract: check with installed 16 finds update 18, downloads nothing',
      () async {
        int downloads = 0;
        final UpdateController controller = _controller(
          currentCode: 16,
          download: (UpdateRelease release, DownloadProgress onProgress) async {
            downloads += 1;
            throw StateError('must not download on check');
          },
        );
        await controller.checkForUpdates();
        expect(controller.state.status, UpdateStatus.updateAvailable);
        expect(controller.state.currentCode, 16);
        expect(controller.state.latest?.versionCode, 18);
        expect(controller.state.previous?.versionCode, 16);
        expect(downloads, 0);
      },
    );

    test(
      'contract: check with installed 18 reports up to date',
      () async {
        final UpdateController controller = _controller(currentCode: 18);
        await controller.checkForUpdates();
        expect(controller.state.status, UpdateStatus.upToDate);
      },
    );

    test(
      'contract: a dead manifest URL surfaces an error without crashing',
      () async {
        final UpdateController controller = _controller(
          fetchError: StateError('HTTP 500'),
        );
        await controller.checkForUpdates();
        expect(controller.state.status, UpdateStatus.error);
        expect(controller.state.error, isNotEmpty);
      },
    );

    test(
      'contract: verified download stages the installer, then it launches',
      () async {
        final _FakeInstaller installer = _FakeInstaller(
          const ApkInstallResult(ApkInstallOutcome.opened, 'ok'),
        );
        final UpdateController controller = _controller(installer: installer);
        await controller.checkForUpdates();
        await controller.downloadUpdate();
        expect(controller.state.status, UpdateStatus.readyToInstall);
        expect(controller.state.targetCode, 18);
        expect(controller.state.apkPath, isNotEmpty);
        await controller.installStaged();
        expect(controller.state.status, UpdateStatus.waitingInstaller);
        expect(installer.launched, hasLength(1));
      },
    );

    test(
      'contract: checksum mismatch deletes the file and never launches',
      () async {
        final _FakeInstaller installer = _FakeInstaller(
          const ApkInstallResult(ApkInstallOutcome.opened, 'ok'),
        );
        final UpdateController controller = _controller(
          installer: installer,
          download: (UpdateRelease release, DownloadProgress onProgress) async {
            final Directory dir =
                await Directory.systemTemp.createTemp('calcar-update-test');
            final File file = File('${dir.path}/calcar-update.apk');
            await file.writeAsBytes(utf8.encode('tampered'), flush: true);
            return file;
          },
        );
        await controller.checkForUpdates();
        await controller.downloadUpdate();
        expect(controller.state.status, UpdateStatus.error);
        expect(installer.launched, isEmpty);
      },
    );

    test(
      'contract: installer launch failure is an error, not a crash',
      () async {
        final UpdateController controller = _controller(
          installer: _FakeInstaller(
            const ApkInstallResult(ApkInstallOutcome.failed, 'no app'),
          ),
        );
        await controller.checkForUpdates();
        await controller.downloadUpdate();
        await controller.installStaged();
        expect(controller.state.status, UpdateStatus.error);
        expect(controller.state.error, isNotEmpty);
      },
    );
  });

  group('rollback flow', () {
    test(
      'contract: rollback from 18 resolves previous 16, never 17',
      () async {
        // Previous points at 16 with the test bytes hash, so a full
        // rollback run stages version 16 end to end.
        const String rollbackBody = '''
{
  "latest": {
    "versionCode": 18,
    "versionName": "0.1.0+18",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-18/calcar.apk",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "previous": {
    "versionCode": 16,
    "versionName": "0.1.0+16",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-16/calcar.apk",
    "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  }
}
''';
        final _FakeInstaller installer = _FakeInstaller(
          const ApkInstallResult(ApkInstallOutcome.opened, 'ok'),
        );
        final UpdateController controller = UpdateController(
          fetchManifest: () async => UpdateManifest.parse(rollbackBody),
          readCurrentCode: () async => 18,
          downloadApk: (UpdateRelease release, DownloadProgress onProgress) async {
            final Directory dir =
                await Directory.systemTemp.createTemp('calcar-rb-test');
            final File file = File('${dir.path}/calcar-update.apk');
            await file.writeAsBytes(_apkBytes, flush: true);
            return file;
          },
          installer: installer,
        );
        await controller.checkForUpdates();
        expect(controller.state.canRollback, isTrue);
        await controller.downloadRollback();
        expect(controller.state.status, UpdateStatus.readyToInstall);
        expect(controller.state.targetCode, 16);
        await controller.installStaged();
        expect(controller.state.status, UpdateStatus.waitingInstaller);
        expect(installer.launched, hasLength(1));
      },
    );

    test(
      'contract: no previous release means rollback refuses with a reason',
      () async {
        final UpdateManifest first = UpdateManifest(
          latest: UpdateManifest.parse(_manifestBody).latest,
        );
        final UpdateController controller = _controller(
          manifest: first,
          currentCode: 18,
        );
        await controller.checkForUpdates();
        expect(controller.state.canRollback, isFalse);
        await controller.downloadRollback();
        expect(controller.state.status, UpdateStatus.error);
        expect(controller.state.error, contains('No previous release'));
      },
    );
  });
}
