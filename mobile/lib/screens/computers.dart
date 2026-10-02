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

  /// Empty-state refresh. Null renders the static empty frame with no
  /// refresh affordance. Non-null adds pull-to-refresh over a scrollable
  /// empty body plus an explicit refresh button, and must call the
  /// devices refresh exactly once per gesture.
  final Future<void> Function()? onRefresh;

  const ComputersScreen({
    super.key,
    this.onAddComputer,
    this.onOpenUpdate,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final Future<void> Function()? refresh = onRefresh;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Computers'),
        actions: <Widget>[
          if (refresh != null)
            IconButton(
              key: const ValueKey('computers-refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => refresh(),
            ),
        ],
      ),
      body: refresh == null
          ? Center(child: _emptyColumn())
          : RefreshIndicator(
              onRefresh: refresh,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return SingleChildScrollView(
                    // Always scrollable so the empty body still
                    // overscrolls into pull refresh instead of swallowing
                    // the gesture.
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(child: _emptyColumn()),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget _emptyColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
    );
  }
}
