// Manual app update screen. One tap from the main screen opens it,
// and every destructive step stays manual: check, download, verify,
// then the OS installer with its own confirmation. No background
// checks, no silent installs, no auto anything.
import 'package:calcar/update/update_controller.dart';
import 'package:calcar/update/update_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class UpdateScreen extends ConsumerWidget {
  const UpdateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final UpdateState state = ref.watch(updateControllerProvider);
    final UpdateController controller =
        ref.read(updateControllerProvider.notifier);
    final bool busy = state.busy;
    return Scaffold(
      appBar: AppBar(title: const Text('App updates')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _headline(state),
              key: const ValueKey('update-status'),
            ),
            const SizedBox(height: 8),
            Text(_versions(state)),
            if (state.error.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                state.error,
                key: const ValueKey('update-error'),
              ),
            ],
            const SizedBox(height: 16),
            if (state.status == UpdateStatus.checking ||
                state.status == UpdateStatus.downloading) ...<Widget>[
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],
            FilledButton(
              key: const ValueKey('update-check'),
              onPressed: busy ? null : controller.checkForUpdates,
              child: const Text('Check for updates'),
            ),
            if (state.status == UpdateStatus.updateAvailable) ...<Widget>[
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('update-download'),
                onPressed: busy ? null : controller.downloadUpdate,
                child: Text(
                  'Download ${state.latest?.versionName ?? ''}',
                ),
              ),
            ],
            if (state.status == UpdateStatus.readyToInstall) ...<Widget>[
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('update-install'),
                onPressed: busy ? null : controller.installStaged,
                child: const Text('Install in Android'),
              ),
            ],
            if (state.canRollback) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('update-rollback'),
                onPressed: busy ? null : controller.downloadRollback,
                child: Text(
                  'Roll back to ${state.previous?.versionName ?? ''}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _headline(UpdateState state) {
    switch (state.status) {
      case UpdateStatus.idle:
        return 'Check whether a newer Calcar build is published.';
      case UpdateStatus.checking:
        return 'Checking for updates...';
      case UpdateStatus.upToDate:
        return 'Already up to date.';
      case UpdateStatus.updateAvailable:
        return 'Update available.';
      case UpdateStatus.downloading:
        return 'Downloading and verifying...';
      case UpdateStatus.readyToInstall:
        return 'Verified. Android will ask you to confirm the install.';
      case UpdateStatus.waitingInstaller:
        return 'Android installer opened. Confirm there to finish.';
      case UpdateStatus.error:
        return 'Update failed.';
    }
  }

  String _versions(UpdateState state) {
    final StringBuffer out = StringBuffer();
    out.write('Current: ${state.currentCode?.toString() ?? 'unknown'}');
    final UpdateRelease? latest = state.latest;
    if (latest != null) {
      out.write('  Latest: ${latest.versionCode}');
    }
    final UpdateRelease? previous = state.previous;
    if (previous != null) {
      out.write('  Previous: ${previous.versionCode}');
    } else if (state.currentCode != null) {
      out.write('  Previous: none');
    }
    return out.toString();
  }
}
