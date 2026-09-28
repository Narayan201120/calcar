import 'package:flutter/material.dart';

/// My Computers: name, online state, workflow rows with status chips.
/// Slice 1 shows the empty state only. Snapshot fetch plus Riverpod
/// wiring lands with the backend client in slice 2.
class ComputersScreen extends StatelessWidget {
  /// Opens the single-use pairing flow. Null leaves the button disabled
  /// rather than silently doing nothing, so missing wiring fails visibly.
  final VoidCallback? onAddComputer;

  /// Opens the manual app update screen. Same null rule as above.
  final VoidCallback? onOpenUpdate;

  const ComputersScreen({super.key, this.onAddComputer, this.onOpenUpdate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Computers')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No computers yet'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onAddComputer,
              child: const Text('Add Computer'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: onOpenUpdate,
              child: const Text('Check for app updates'),
            ),
          ],
        ),
      ),
    );
  }
}
