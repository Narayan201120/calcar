// My Computers wired to devicesControllerProvider.
//
// One snapshot on entry, one snapshot per pull refresh, and rows derived
// from the device snapshot alone. The empty and error frames refresh too,
// so a stale empty list is escapable without a restart. Workflow rows stay
// on computer detail: a list fetch is one call by contract, so the list
// never fans out into a snapshot per computer. Navigation stays with
// the host.
import 'package:calcar/api/models.dart';
import 'package:calcar/screens/computers.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WiredComputersScreen extends ConsumerStatefulWidget {
  /// Tapped computer. The host owns the route and the detail screen, so
  /// the wrapper never pushes a route of its own accord.
  final void Function(Device device)? onOpenComputer;

  const WiredComputersScreen({super.key, this.onOpenComputer});

  @override
  ConsumerState<WiredComputersScreen> createState() =>
      _WiredComputersScreenState();
}

class _WiredComputersScreenState extends ConsumerState<WiredComputersScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred by a microtask: refresh sets provider state synchronously,
    // and a provider must never be modified while the tree is building.
    // Skipped when a refresh already completed, so a cold-start gate plus
    // this mount costs exactly one fetch instead of two.
    if (!ref.read(devicesControllerProvider).loaded) {
      Future<void>.microtask(_pullRefresh);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DevicesState state = ref.watch(devicesControllerProvider);
    final List<Device> computers = state.computers;
    if (computers.isEmpty) {
      return _coldList(state);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Computers'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('computers-update'),
            icon: const Icon(Icons.system_update),
            tooltip: 'App updates',
            onPressed: () => Navigator.of(context).pushNamed('/update'),
          ),
          IconButton(
            key: const ValueKey('computers-add'),
            icon: const Icon(Icons.add),
            tooltip: 'Add Computer',
            onPressed: () =>
                Navigator.of(context).pushNamed('/add-computer'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _pullRefresh,
        child: ListView.builder(
          // Always scrollable so a short list still overscrolls into
          // pull refresh instead of swallowing the gesture.
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: computers.length,
          itemBuilder: (BuildContext context, int index) =>
              _row(state, computers[index]),
        ),
      ),
    );
  }

  Future<void> _pullRefresh() {
    return ref.read(devicesControllerProvider.notifier).refresh();
  }

  /// No managed computers yet. The pure screen owns that copy and the
  /// Add Computer affordance, so it is returned whole rather than
  /// retyped here. A failed fetch is not an empty list and says so.
  /// Both frames carry the same refresh affordance as the list, so a
  /// stale empty list or a failed load is escapable without a restart.
  /// The empty screen navigates to the single-use pairing route, which
  /// the shell owns, so this wrapper never builds pairing state itself.
  Widget _coldList(DevicesState state) {
    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('My Computers'),
          actions: <Widget>[
            IconButton(
              key: const ValueKey('computers-refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _pullRefresh,
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _pullRefresh,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                // Always scrollable so the error frame still overscrolls
                // into pull refresh instead of swallowing the gesture.
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Could not load computers: ${state.error}',
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          key: const ValueKey('computers-retry'),
                          onPressed: _pullRefresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    return ComputersScreen(
      onAddComputer: () => Navigator.of(context).pushNamed('/add-computer'),
      onOpenUpdate: () => Navigator.of(context).pushNamed('/update'),
      onRefresh: _pullRefresh,
    );
  }

  Widget _row(DevicesState state, Device device) {
    return ListTile(
      key: ValueKey('computer-row-${device.deviceId}'),
      title: Text(device.displayName),
      subtitle: Text(
        '${device.deviceId}  ${deviceStateOf(device, state.presenceById)}',
      ),
      onTap: () => widget.onOpenComputer?.call(device),
    );
  }
}
