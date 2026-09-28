// Manual update state machine. Check never downloads, download never
// installs, install only opens the OS sheet. Every seam is injected
// so tests drive the whole flow with fakes and no network.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'apk_downloader.dart';
import 'apk_installer.dart';
import 'update_manifest.dart';
import 'update_service.dart';

/// Stable manifest address. GitHub serves the update.json asset of the
/// newest mobile release here, so the app never chases a changing URL.
const String kUpdateManifestUrl =
    'https://github.com/Narayan201120/calcar/releases/latest/download/update.json';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  readyToInstall,
  waitingInstaller,
  error,
}

class UpdateState {
  final UpdateStatus status;
  final int? currentCode;
  final UpdateRelease? latest;
  final UpdateRelease? previous;
  final String apkPath;
  final int? targetCode;
  final String error;

  /// Download fraction 0 to 1, or null when the server gave no length.
  final double? progress;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.currentCode,
    this.latest,
    this.previous,
    this.apkPath = '',
    this.targetCode,
    this.error = '',
    this.progress,
  });

  bool get busy {
    return status == UpdateStatus.checking ||
        status == UpdateStatus.downloading;
  }

  bool get canRollback {
    final UpdateRelease? prev = previous;
    final int? current = currentCode;
    return prev != null && current != null && prev.versionCode < current;
  }

  UpdateState copyWith({
    UpdateStatus? status,
    int? currentCode,
    UpdateRelease? latest,
    UpdateRelease? previous,
    bool clearPrevious = false,
    String? apkPath,
    int? targetCode,
    bool clearTarget = false,
    String? error,
    double? progress,
    bool clearProgress = false,
  }) {
    return UpdateState(
      status: status ?? this.status,
      currentCode: currentCode ?? this.currentCode,
      latest: latest ?? this.latest,
      previous: clearPrevious ? null : (previous ?? this.previous),
      apkPath: apkPath ?? this.apkPath,
      targetCode: clearTarget ? null : (targetCode ?? this.targetCode),
      error: error ?? this.error,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }
}

typedef FetchManifestFn = Future<UpdateManifest> Function();
typedef ReadCurrentCodeFn = Future<int> Function();
typedef DownloadApkFn = Future<File> Function(
  UpdateRelease release,
  DownloadProgress onProgress,
);

class UpdateController extends StateNotifier<UpdateState> {
  UpdateController({
    required FetchManifestFn fetchManifest,
    required ReadCurrentCodeFn readCurrentCode,
    required DownloadApkFn downloadApk,
    required ApkInstaller installer,
  })  : _fetchManifest = fetchManifest,
        _readCurrentCode = readCurrentCode,
        _downloadApk = downloadApk,
        _installer = installer,
        super(const UpdateState());

  final FetchManifestFn _fetchManifest;
  final ReadCurrentCodeFn _readCurrentCode;
  final DownloadApkFn _downloadApk;
  final ApkInstaller _installer;

  bool _gone = false;

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  void _emit(UpdateState next) {
    if (!_gone) {
      state = next;
    }
  }

  /// Reads the manifest and compares against the installed versionCode.
  /// Downloads nothing by contract: an up-to-date phone stays quiet.
  Future<void> checkForUpdates() async {
    if (state.busy) {
      return;
    }
    _dropStaged();
    _emit(
      state.copyWith(
        status: UpdateStatus.checking,
        error: '',
        clearTarget: true,
        apkPath: '',
        clearProgress: true,
      ),
    );
    try {
      final UpdateManifest manifest = await _fetchManifest();
      final int current = await _readCurrentCode();
      if (current <= 0) {
        throw const FormatException('installed versionCode is invalid');
      }
      if (manifest.updateAvailable(current)) {
        _emit(
          state.copyWith(
            status: UpdateStatus.updateAvailable,
            currentCode: current,
            latest: manifest.latest,
            previous: manifest.previous,
            clearPrevious: manifest.previous == null,
          ),
        );
      } else {
        _emit(
          state.copyWith(
            status: UpdateStatus.upToDate,
            currentCode: current,
            latest: manifest.latest,
            previous: manifest.previous,
            clearPrevious: manifest.previous == null,
          ),
        );
      }
    } on Object catch (error) {
      _emit(
        state.copyWith(
          status: UpdateStatus.error,
          error: '$error',
        ),
      );
    }
  }

  /// Downloads plus verifies the newest release.
  Future<void> downloadUpdate() => _downloadTarget(latest: true);

  /// Downloads plus verifies the previous release from the manifest,
  /// never current minus one, so gaps like 16 then 18 resolve to 16.
  Future<void> downloadRollback() => _downloadTarget(latest: false);

  Future<void> _downloadTarget({required bool latest}) async {
    if (state.busy) {
      return;
    }
    final UpdateRelease? target =
        latest ? state.latest : state.previous;
    if (target == null) {
      _emit(
        state.copyWith(
          status: UpdateStatus.error,
          error: latest
              ? 'Check for updates first.'
              : 'No previous release available.',
        ),
      );
      return;
    }
    final int? current = state.currentCode;
    if (!latest && current != null && target.versionCode >= current) {
      _emit(
        state.copyWith(
          status: UpdateStatus.error,
          error: 'No previous release available.',
        ),
      );
      return;
    }
    _dropStaged();
    _emit(
      state.copyWith(
        status: UpdateStatus.downloading,
        error: '',
        clearTarget: true,
        apkPath: '',
        clearProgress: true,
      ),
    );
    double lastReported = -1;
    try {
      final File apk = await _downloadApk(target, (int received, int? total) {
        final double? fraction = total == null || total <= 0
            ? null
            : received / total;
        if (fraction == null) {
          return;
        }
        // One emit per percent point: chunk callbacks fire far faster
        // than the screen can usefully repaint.
        if (fraction - lastReported >= 0.01 || fraction >= 1) {
          lastReported = fraction;
          _emit(state.copyWith(progress: fraction));
        }
      });
      try {
        await verifyApkSha256(apk, target.sha256);
      } on Object catch (_) {
        try {
          if (apk.existsSync()) {
            apk.deleteSync();
          }
        } on Object {
          // The verify already failed; a leftover file must still go,
          // and its deletion failing changes nothing about the verdict.
        }
        rethrow;
      }
      _emit(
        state.copyWith(
          status: UpdateStatus.readyToInstall,
          apkPath: apk.path,
          targetCode: target.versionCode,
        ),
      );
    } on Object catch (error) {
      _emit(
        state.copyWith(
          status: UpdateStatus.error,
          error: '$error',
        ),
      );
    }
  }

  /// Opens the OS installer for the verified staged file. A checksum
  /// failure can never arrive here: download refuses to stage it.
  Future<void> installStaged() async {
    if (state.busy || state.apkPath.isEmpty) {
      return;
    }
    final ApkInstallResult result =
        await _installer.install(state.apkPath);
    if (result.outcome == ApkInstallOutcome.opened) {
      _emit(state.copyWith(status: UpdateStatus.waitingInstaller));
    } else {
      _emit(
        state.copyWith(
          status: UpdateStatus.error,
          error: result.detail.isEmpty
              ? 'The installer refused the file.'
              : result.detail,
        ),
      );
    }
  }

  void _dropStaged() {
    if (state.apkPath.isEmpty) {
      return;
    }
    try {
      final File staged = File(state.apkPath);
      if (staged.existsSync()) {
        staged.deleteSync();
      }
    } on Object {
      // Best effort hygiene only; a leftover staged file is inert
      // because only a freshly verified path is ever installed.
    }
  }
}

/// Production wiring: stable manifest URL, real versionCode from the
/// installed package, real download into the app temp dir, real OS
/// installer sheet.
final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>(
  (Ref ref) {
    return UpdateController(
      fetchManifest: () async {
        final http.Client client = http.Client();
        try {
          return await fetchUpdateManifest(
            client,
            Uri.parse(kUpdateManifestUrl),
          );
        } finally {
          client.close();
        }
      },
      readCurrentCode: () async {
        final PackageInfo info = await PackageInfo.fromPlatform();
        return int.tryParse(info.buildNumber) ?? 0;
      },
      downloadApk: (UpdateRelease release, DownloadProgress onProgress) {
        return downloadApk(
          apkUrl: release.apkUrl,
          versionCode: release.versionCode,
          onProgress: onProgress,
        );
      },
      installer: const OpenFilexApkInstaller(),
    );
  },
);
