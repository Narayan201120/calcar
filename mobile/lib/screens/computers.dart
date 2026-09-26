import 'package:flutter/material.dart';

/// My Computers: name, online state, workflow rows with status chips.
/// Slice 1 shows the empty state only. Snapshot fetch plus Riverpod
/// wiring lands with the backend client in slice 2.
class ComputersScreen extends StatelessWidget {
  const ComputersScreen({super.key});

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
              onPressed: () {},
              child: const Text('Add Computer'),
            ),
          ],
        ),
      ),
    );
  }
}
