// Computer detail wired to computerControllerProvider: one snapshot on
// entry for the header and its workflow rows, plus sysinfo fetched
// lazily over the agent channel the first time the Owner expands it.
// Sysinfo stays collapsed and cached per computer, so scrolling back into
// this screen never re-hits the agent.
import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/screens/computer_detail.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/screens/wired/wired_workflow_view.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One sysinfo fetch per computer, held for the app session. The pure
/// screen already guards a second expand, so a cache here only saves the
/// navigate-away and come-back case.
final sysinfoProvider = FutureProvider.family<Sysinfo, String>(
  (Ref ref, String computerId) {
    // Read the channel now: the fetch itself runs later, off frame, and
    // a provider may not be watched once its body has returned.
    final AgentChannelClient channel = ref.watch(agentChannelProvider);
    return Future<Sysinfo>(
      () => sysinfoFrom(channel.fetchSysinfo(computerId)),
    );
  },
);

/// Agent sysinfo body to the four fields the pure screen renders. A
/// missing key reads blank rather than guessed: a wrong CPU string is
/// worse than an empty one.
Sysinfo sysinfoFrom(Map<String, dynamic> body) {
  return Sysinfo(
    cpu: (body['cpu'] ?? '').toString(),
    ram: (body['ram'] ?? '').toString(),
    gpu: (body['gpu'] ?? '').toString(),
    disk: (body['disk'] ?? '').toString(),
  );
}

class WiredComputerDetailScreen extends ConsumerStatefulWidget {
  final String computerId;

  /// Tapped workflow. Without one the wrapper opens the wired workflow
  /// view itself, since the buffers live per workflow and nowhere else.
  final void Function(WorkflowSummary workflow)? onOpenWorkflow;

  const WiredComputerDetailScreen({
    super.key,
    required this.computerId,
    this.onOpenWorkflow,
  });

  @override
  ConsumerState<WiredComputerDetailScreen> createState() =>
      _WiredComputerDetailScreenState();
}

class _WiredComputerDetailScreenState
    extends ConsumerState<WiredComputerDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred by a microtask: refresh sets provider state synchronously,
    // and a provider must never be modified while the tree is building.
    Future<void>.microtask(_load);
  }

  void _load() {
    ref.read(computerControllerProvider(widget.computerId).notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ComputerState state =
        ref.watch(computerControllerProvider(widget.computerId));
    final ComputerSnapshot? snapshot = state.snapshot;
    if (snapshot == null) {
      return _placeholder(state);
    }
    return ComputerDetailScreen(
      computer: computerSummaryOf(snapshot),
      onExpandSysinfo: _fetchSysinfo,
      onOpenWorkflow: widget.onOpenWorkflow ?? _openWorkflow,
    );
  }

  Future<Sysinfo> _fetchSysinfo() {
    return ref.read(sysinfoProvider(widget.computerId).future);
  }

  Widget _placeholder(ComputerState state) {
    if (state.error.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.computerId)),
      body: Center(
        child: Text('Could not load this computer: ${state.error}'),
      ),
    );
  }

  void _openWorkflow(WorkflowSummary workflow) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => WiredWorkflowView(
          workflow: WorkflowKey(
            computerId: widget.computerId,
            workflowId: workflow.workflowId,
          ),
          title: workflow.title,
        ),
      ),
    );
  }
}

/// The one mapping from a state snapshot to the pure screen's rows.
ComputerSummary computerSummaryOf(ComputerSnapshot snapshot) {
  return ComputerSummary(
    deviceId: snapshot.deviceId,
    displayName: snapshot.displayName,
    online: snapshot.online,
    lastSeenMillis: snapshot.lastSeenMillis,
    workflows: snapshot.workflows
        .map(
          (WorkflowRow row) => WorkflowSummary(
            workflowId: row.workflowId,
            title: row.title,
            status: row.status,
          ),
        )
        .toList(growable: false),
  );
}
