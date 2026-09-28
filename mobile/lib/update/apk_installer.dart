// Android installer launch, isolated behind one interface. The
// production path hands the verified APK to the OS through the
// plugin-owned FileProvider as a content URI, never a file URI, and
// the OS shows its own install confirmation. Nothing installs
// silently: this call only opens the installer, the user confirms.
library;

import 'package:open_filex/open_filex.dart';

enum ApkInstallOutcome {
  opened,
  failed,
}

class ApkInstallResult {
  final ApkInstallOutcome outcome;
  final String detail;

  const ApkInstallResult(this.outcome, this.detail);
}

abstract class ApkInstaller {
  Future<ApkInstallResult> install(String apkPath);
}

/// Opens the staged APK with the system installer sheet.
class OpenFilexApkInstaller implements ApkInstaller {
  const OpenFilexApkInstaller();

  @override
  Future<ApkInstallResult> install(String apkPath) async {
    try {
      final OpenResult opened = await OpenFilex.open(
        apkPath,
        type: 'application/vnd.android.package-archive',
      );
      switch (opened.type) {
        case ResultType.done:
          return const ApkInstallResult(
            ApkInstallOutcome.opened,
            'Android installer opened',
          );
        case ResultType.fileNotFound:
        case ResultType.noAppToOpen:
        case ResultType.permissionDenied:
        case ResultType.error:
          return ApkInstallResult(
            ApkInstallOutcome.failed,
            opened.message.isEmpty ? 'installer refused the file' : opened.message,
          );
      }
    } on Object catch (error) {
      return ApkInstallResult(ApkInstallOutcome.failed, '$error');
    }
  }
}
