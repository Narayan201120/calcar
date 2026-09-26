// My Computers wired to devicesControllerProvider.
//
// One snapshot on entry, one snapshot per pull refresh, and rows derived
// from the device snapshot alone. Workflow rows stay on computer detail:
// a list fetch is one call by contract, so the list never fans out into
// a snapshot per computer. Navigation stays with the host.
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
    Future<void>.microtask(_pullRefresh);
  }

  @override
  Widget build(BuildContext context) {
    final DevicesState state = ref.watch(devicesControllerProvider);
    final List<Device> computers = state.computers;
    if (computers.isEmpty) {
      return _coldList(state);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('My Computers')),
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
  Widget _coldList(DevicesState state) {
    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Computers')),
        body: Center(
          child: Text('Could not load computers: ${state.error}'),
        ),
      );
    }
    return const ComputersScreen();
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
