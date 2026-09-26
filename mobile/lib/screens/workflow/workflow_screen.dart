import 'package:calcar/screens/workflow/approval_card.dart';
import 'package:calcar/screens/workflow/chat_tab.dart';
import 'package:calcar/screens/workflow/files_tab.dart';
import 'package:calcar/screens/workflow/terminal_tab.dart';
import 'package:calcar/screens/workflow/workflow_models.dart';
import 'package:flutter/material.dart';

/// Workflow view with Activity default, then Chat, Terminal, Files.
/// Everything arrives through the constructor: the snapshot, the clock,
/// and the action callbacks. No providers, no client calls, no sockets,
/// so dispose closes nothing.
class WorkflowScreen extends StatelessWidget {
  final WorkflowDetail workflow;

  /// Clock for approval countdowns. Defaults to now when omitted so
  /// production callers pass nothing and tests pin a fixed instant.
  final int? nowMillis;

  final void Function(String approvalId, bool approved)? onResolveApproval;
  final void Function(String body, {required bool destructive})?
      onSendMessage;
  final void Function(String messageId)? onRetryMessage;
  final void Function(int page)? onTerminalPage;

  const WorkflowScreen({
    super.key,
    required this.workflow,
    this.nowMillis,
    this.onResolveApproval,
    this.onSendMessage,
    this.onRetryMessage,
    this.onTerminalPage,
  });

  @override
  Widget build(BuildContext context) {
    final int clock =
        nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(workflow.title),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: 'Activity'),
              Tab(text: 'Chat'),
              Tab(text: 'Terminal'),
              Tab(text: 'Files'),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            _ActivityTab(
              approvals: workflow.approvals,
              events: workflow.activity,
              nowMillis: clock,
              onResolve: onResolveApproval,
            ),
            ChatTab(
              messages: workflow.messages,
              onSend: onSendMessage,
              onRetry: onRetryMessage,
            ),
            TerminalTab(
              lines: workflow.terminalLines,
              totalLines: workflow.terminalTotalLines,
              page: workflow.terminalPage,
              totalPages: workflow.terminalTotalPages,
              onPage: onTerminalPage,
            ),
            FilesTab(
              hunks: workflow.files,
              truncated: workflow.filesTruncated,
            ),
          ],
        ),
      ),
    );
  }
}

/// Activity feed: approval cards first, then event rows. Builder based.
class _ActivityTab extends StatelessWidget {
  final List<ApprovalRequest> approvals;
  final List<ActivityEntry> events;
  final int nowMillis;
  final void Function(String approvalId, bool approved)? onResolve;

  const _ActivityTab({
    required this.approvals,
    required this.events,
    required this.nowMillis,
    this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    final int itemCount = approvals.length + events.length;
    return ListView.builder(
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (index < approvals.length) {
          return ApprovalCard(
            approval: approvals[index],
            nowMillis: nowMillis,
            onResolve: onResolve,
          );
        }
        final ActivityEntry event = events[index - approvals.length];
        return ListTile(
          key: ValueKey('event-${event.id}'),
          title: Text(event.text),
          subtitle: Text(event.kind),
        );
      },
    );
  }
}
