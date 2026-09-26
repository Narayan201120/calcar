import 'dart:async';

import 'package:flutter/material.dart';

/// Row data for one workflow on a computer. Status mirrors the agent
/// workflow states: running, waiting_input, waiting_approval, completed,
/// failed, stopped.
class WorkflowSummary {
  final String workflowId;
  final String title;
  final String status;

  const WorkflowSummary({
    required this.workflowId,
    required this.title,
    required this.status,
  });
}

/// Constructor-fed view of one managed computer plus its workflows.
class ComputerSummary {
  final String deviceId;
  final String displayName;
  final bool online;
  final int lastSeenMillis;
  final List<WorkflowSummary> workflows;

  const ComputerSummary({
    required this.deviceId,
    required this.displayName,
    required this.online,
    required this.lastSeenMillis,
    required this.workflows,
  });
}

/// Lazily fetched sysinfo block: CPU, RAM, GPU, disk.
class Sysinfo {
  final String cpu;
  final String ram;
  final String gpu;
  final String disk;

  const Sysinfo({
    required this.cpu,
    required this.ram,
    required this.gpu,
    required this.disk,
  });
}

/// Human label for an agent workflow status. Unknown states pass through
/// raw so new backend states stay visible instead of blank.
String workflowStatusLabel(String status) {
  switch (status) {
    case 'running':
      return 'Running';
    case 'waiting_input':
      return 'Waiting input';
    case 'waiting_approval':
      return 'Waiting approval';
    case 'completed':
      return 'Completed';
    case 'failed':
      return 'Failed';
    case 'stopped':
      return 'Stopped';
    default:
      return status;
  }
}

Color _chipColor(String status) {
  switch (status) {
    case 'running':
      return Colors.green.shade100;
    case 'waiting_input':
      return Colors.amber.shade100;
    case 'waiting_approval':
      return Colors.orange.shade100;
    case 'completed':
      return Colors.blue.shade100;
    case 'failed':
      return Colors.red.shade100;
    case 'stopped':
      return Colors.grey.shade300;
    default:
      return Colors.grey.shade200;
  }
}

/// Status chip for one workflow row. Pure render, no callbacks.
class WorkflowStatusChip extends StatelessWidget {
  final String status;

  const WorkflowStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Chip(
      key: ValueKey('status-chip-$status'),
      label: Text(workflowStatusLabel(status)),
      backgroundColor: _chipColor(status),
    );
  }
}

/// Computer detail: workflows are the primary list, sysinfo sits collapsed
/// below and is fetched lazily through [onExpandSysinfo] on first expand.
/// All data arrives through the constructor. No providers, no client calls,
/// no sockets, so dispose closes nothing.
class ComputerDetailScreen extends StatefulWidget {
  final ComputerSummary computer;

  /// Preloaded sysinfo. When null the tile fetches via [onExpandSysinfo].
  final Sysinfo? sysinfo;

  /// Lazy fetch fired once on first sysinfo expand. Null means no fetch.
  final Future<Sysinfo> Function()? onExpandSysinfo;

  /// Fired when a workflow row is tapped. Navigation stays with the caller.
  final void Function(WorkflowSummary workflow)? onOpenWorkflow;

  const ComputerDetailScreen({
    super.key,
    required this.computer,
    this.sysinfo,
    this.onExpandSysinfo,
    this.onOpenWorkflow,
  });

  @override
  State<ComputerDetailScreen> createState() => _ComputerDetailScreenState();
}

class _ComputerDetailScreenState extends State<ComputerDetailScreen> {
  Sysinfo? _fetched;
  bool _loading = false;

  Future<void> _maybeFetchSysinfo() async {
    if (widget.sysinfo != null || _fetched != null || _loading) {
      return;
    }
    final Future<Sysinfo> Function()? fetch = widget.onExpandSysinfo;
    if (fetch == null) {
      return;
    }
    setState(() {
      _loading = true;
    });
    final Sysinfo info = await fetch();
    if (!mounted) {
      return;
    }
    setState(() {
      _fetched = info;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Header row plus one row per workflow plus the sysinfo tile.
    final int itemCount = 1 + widget.computer.workflows.length + 1;
    return Scaffold(
      appBar: AppBar(title: Text(widget.computer.displayName)),
      body: ListView.builder(
        itemCount: itemCount,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return _headerTile();
          }
          final int workflowIndex = index - 1;
          if (workflowIndex < widget.computer.workflows.length) {
            return _workflowRow(widget.computer.workflows[workflowIndex]);
          }
          return _sysinfoTile();
        },
      ),
    );
  }

  Widget _headerTile() {
    return ListTile(
      key: const ValueKey('computer-online-state'),
      title: Text(widget.computer.online ? 'Online' : 'Offline'),
      subtitle: Text(widget.computer.deviceId),
    );
  }

  Widget _workflowRow(WorkflowSummary workflow) {
    return ListTile(
      key: ValueKey('workflow-row-${workflow.workflowId}'),
      title: Text(workflow.title),
      trailing: WorkflowStatusChip(status: workflow.status),
      onTap: () => widget.onOpenWorkflow?.call(workflow),
    );
  }

  Widget _sysinfoTile() {
    return ExpansionTile(
      key: const ValueKey('sysinfo-tile'),
      title: const Text('System info'),
      subtitle: const Text('CPU, RAM, GPU, disk'),
      onExpansionChanged: (bool open) {
        if (open) {
          unawaited(_maybeFetchSysinfo());
        }
      },
      children: <Widget>[_sysinfoBody()],
    );
  }

  Widget _sysinfoBody() {
    final Sysinfo? info = widget.sysinfo ?? _fetched;
    if (info != null) {
      final List<MapEntry<String, String>> rows = <MapEntry<String, String>>[
        MapEntry('CPU', info.cpu),
        MapEntry('RAM', info.ram),
        MapEntry('GPU', info.gpu),
        MapEntry('Disk', info.disk),
      ];
      return ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (BuildContext context, int index) {
          return ListTile(
            title: Text(rows[index].key),
            subtitle: Text(rows[index].value),
          );
        },
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const ListTile(
      title: Text('Expand to load system info'),
    );
  }
}
