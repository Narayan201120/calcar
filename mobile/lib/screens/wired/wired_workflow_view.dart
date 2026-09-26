// Workflow view wired to workflowControllerProvider for the capped
// buffers and connectionControllerProvider for the banner.
//
// Two rules the pure screen cannot know about:
//
//  1. A drop freezes. Once the banner is up the controller drops every
//     delta and refuses every resolve, so a socket blink can never make
//     the phone report a workflow finished. The pre-connect state is not
//     a drop: nothing has failed yet and the mount snapshot is current,
//     so nothing is frozen until the banner actually rises.
//  2. A reconnect refetches. Freezing clears only through loadSnapshot,
//     which is also what repairs whatever the drop swallowed.
//
// Approval resolves and chat inputs ride the agent channel with a key
// that is stable per item, so a send that lost its ack is never applied
// twice. A failed send is reported, never retried: single resolve wins
// upstream and re-posting would be a second decision.
import 'dart:async';

import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/screens/workflow/chat_tab.dart';
import 'package:calcar/screens/workflow/files_tab.dart';
import 'package:calcar/screens/workflow/workflow_models.dart';
import 'package:calcar/screens/workflow/workflow_screen.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Terminal lines per page. The agent owns the tail and the state layer
/// caps it; the phone only splits the kept tail so the paged tab has
/// something to page over.
const int kTerminalPageLines = 200;

/// Idempotency key for one approval decision. Stable per approval, so a
/// retry after a drop applies at most once, and qualified by the
/// workflow, so two workflows can never collide on it.
String approvalIdempotencyKey(WorkflowKey key, String approvalId) {
  return '${key.workflowId}:$approvalId';
}

class WiredWorkflowView extends ConsumerStatefulWidget {
  /// Which workflow to buffer. Both halves come from the row that was
  /// tapped, never from a global.
  final WorkflowKey workflow;

  /// Title for the app bar. The state layer does not carry workflow
  /// titles, so the caller passes the one it rendered the row from.
  final String title;

  /// Clock for approval countdowns. Tests pin an instant; production
  /// leaves it null and the screen reads the wall clock.
  final int? nowMillis;

  /// Key for the subtree, so a deep link that addresses one approval
  /// inside a workflow gets its own identity. Null uses the plain
  /// computer plus workflow key.
  final String? keyId;

  const WiredWorkflowView({
    super.key,
    required this.workflow,
    required this.title,
    this.nowMillis,
    this.keyId,
  });

  @override
  ConsumerState<WiredWorkflowView> createState() => _WiredWorkflowViewState();
}

class _WiredWorkflowViewState extends ConsumerState<WiredWorkflowView> {
  /// Last transport failure, shown as a strip under the banner.
  String _sendError = '';

  /// Current page of the kept terminal tail, 1-based.
  int _terminalPage = 1;

  /// Client-side input ids. A retry reuses its id, so a send that landed
  /// but lost its ack is never applied twice.
  int _inputCount = 0;

  /// Destructive flag per input id, so a retry replays what was sent.
  final Map<String, bool> _destructiveInputs = <String, bool>{};

  @override
  void initState() {
    super.initState();
    // Deferred by a microtask: a provider must never be modified while
    // the tree is building, and the buffers start one snapshot behind.
    Future<void>.microtask(_loadSnapshot);
  }

  @override
  Widget build(BuildContext context) {
    _listenToConnection();
    final ConnectionState connection = ref.watch(connectionControllerProvider);
    final WorkflowBuffers buffers =
        ref.watch(workflowControllerProvider(widget.workflow));
    final WorkflowController controller = ref.read(
      workflowControllerProvider(widget.workflow).notifier,
    );
    final Widget screen = !controller.snapshotLoaded
        ? _placeholder(controller)
        : _scaffold(buffers, controller, connection);
    return KeyedSubtree(
      key: ValueKey(
        widget.keyId ??
            'workflow-${widget.workflow.computerId}-${widget.workflow.workflowId}',
      ),
      child: screen,
    );
  }

  Widget _scaffold(
    WorkflowBuffers buffers,
    WorkflowController controller,
    ConnectionState connection,
  ) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          if (connection.showBanner)
            _strip(
              'workflow-connection-banner',
              Colors.amber.shade100,
              _bannerText(connection),
            ),
          if (controller.loadError.isNotEmpty)
            _strip(
              'workflow-load-error',
              Colors.red.shade100,
              'Showing the last known state: ${controller.loadError}',
            ),
          if (_sendError.isNotEmpty)
            _strip('workflow-send-error', Colors.red.shade100, _sendError),
          Expanded(child: _tabs(buffers, _clock())),
        ],
      ),
    );
  }

  /// First visit with no snapshot at all. A later visit keeps the buffers
  /// it already holds on screen while the refetch runs, which is the point
  /// of caching the controller per workflow.
  Widget _placeholder(WorkflowController controller) {
    if (controller.loadError.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Text('Could not load this workflow: ${controller.loadError}'),
      ),
    );
  }

  /// The banner owns the screen while it is up: freeze on the way up,
  /// refetch on the way down. Only a workflow that actually froze owes a
  /// refetch, which keeps a cold start to a single snapshot.
  void _listenToConnection() {
    ref.listen<ConnectionState>(
      connectionControllerProvider,
      (_, ConnectionState next) {
        final WorkflowController controller = ref.read(
          workflowControllerProvider(widget.workflow).notifier,
        );
        if (next.showBanner) {
          controller.setFrozen(frozen: true);
          return;
        }
        if (controller.frozen) {
          unawaited(_loadSnapshot());
        }
      },
    );
  }

  /// A failed load emits no state, so the screen nudges itself to show the
  /// error instead of sitting on a stale freeze with nothing to read.
  Future<void> _loadSnapshot() async {
    final bool loaded = await ref
        .read(workflowControllerProvider(widget.workflow).notifier)
        .loadSnapshot();
    if (!loaded && mounted) {
      setState(() {});
    }
  }

  int _clock() {
    return widget.nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  }

  String _bannerText(ConnectionState connection) {
    if (connection.connected) {
      return 'Updates paused, catching up';
    }
    return 'Disconnected, updates paused';
  }

  Widget _strip(String key, Color color, String text) {
    return Container(
      key: ValueKey(key),
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.all(8),
      child: Text(text),
    );
  }

  Widget _tabs(WorkflowBuffers buffers, int clock) {
    return WorkflowScreen(
      workflow: _detailOf(buffers),
      nowMillis: clock,
      onResolveApproval: _resolveApproval,
      onSendMessage: _sendMessage,
      onRetryMessage: _retryMessage,
      onTerminalPage: _showTerminalPage,
    );
  }

  /// The one mapping from capped buffers to the pure screen's tabs.
  /// Terminal paging splits the kept tail, so the notice and the page
  /// controls agree with what the state layer actually holds.
  WorkflowDetail _detailOf(WorkflowBuffers buffers) {
    final int totalPages = _pageCount(buffers.terminalLines.length);
    final int page = _pageOf(buffers.terminalLines.length);
    return WorkflowDetail(
      workflowId: buffers.workflowId,
      title: widget.title,
      status: buffers.status,
      activity: buffers.activity
          .map(
            (BufferedActivity event) => ActivityEntry(
              id: event.id,
              kind: event.kind,
              text: event.text,
              atMillis: event.atMillis,
            ),
          )
          .toList(growable: false),
      approvals: buffers.approvals
          .map(
            (TrackedApproval approval) => ApprovalRequest(
              approvalId: approval.approvalId,
              title: approval.title,
              detail: approval.detail,
              expiresAtMillis: approval.expiresAtMillis,
              resolution: approval.resolution,
              destructive: approval.destructive,
            ),
          )
          .toList(growable: false),
      messages: buffers.chat
          .map(
            (BufferedChat message) => ChatMessage(
              messageId: message.messageId,
              body: message.body,
              outbound: message.outbound,
              sendState: message.sendState,
            ),
          )
          .toList(growable: false),
      terminalLines: buffers.terminalLines.sublist(
        _pageStart(page, buffers.terminalLines.length),
        _pageEnd(page, buffers.terminalLines.length),
      ),
      terminalTotalLines: buffers.terminalTotalLines,
      terminalPage: page,
      terminalTotalPages: totalPages,
      files: buffers.files
          .map(
            (BufferedFile hunk) => FileHunk(
              path: hunk.path,
              diff: hunk.diff,
              truncated: hunk.truncated,
            ),
          )
          .toList(growable: false),
      filesTruncated: buffers.filesTruncated,
    );
  }

  int _pageCount(int lineCount) {
    if (lineCount <= kTerminalPageLines) {
      return 1;
    }
    return (lineCount + kTerminalPageLines - 1) ~/ kTerminalPageLines;
  }

  int _pageOf(int lineCount) {
    final int highest = _pageCount(lineCount);
    if (_terminalPage < 1) {
      return 1;
    }
    if (_terminalPage > highest) {
      return highest;
    }
    return _terminalPage;
  }

  int _pageStart(int page, int lineCount) {
    final int start = (page - 1) * kTerminalPageLines;
    return start > lineCount ? lineCount : start;
  }

  int _pageEnd(int page, int lineCount) {
    final int end = page * kTerminalPageLines;
    return end > lineCount ? lineCount : end;
  }

  void _showTerminalPage(int page) {
    setState(() {
      _terminalPage = page;
    });
  }

  /// The local guard runs before the wire: a frozen, expired, unknown,
  /// or already decided approval records nothing and posts nothing, so
  /// one resolve reaches the agent at most once.
  void _resolveApproval(String approvalId, bool approved) {
    final AgentChannelClient channel = ref.read(agentChannelProvider);
    final WorkflowController controller = ref.read(
      workflowControllerProvider(widget.workflow).notifier,
    );
    if (!controller.resolveApproval(
      approvalId,
      approved: approved,
      nowMillis: _clock(),
    )) {
      return;
    }
    final String requestId =
        approvalIdempotencyKey(widget.workflow, approvalId);
    _post(
      () => channel.postApprovalResolve(
        workflowId: widget.workflow.workflowId,
        requestId: requestId,
        allow: approved,
      ),
    );
  }

  void _sendMessage(String body, {required bool destructive}) {
    final AgentChannelClient channel = ref.read(agentChannelProvider);
    final String inputId = _nextInputId();
    _destructiveInputs[inputId] = destructive;
    _post(
      () => channel.postInput(
        workflowId: widget.workflow.workflowId,
        inputId: inputId,
        body: body,
        destructive: destructive,
      ),
    );
  }

  /// Retry replays the stored body under the original input id, which is
  /// the whole point of a client-side id: the agent dedupes it.
  void _retryMessage(String messageId) {
    final AgentChannelClient channel = ref.read(agentChannelProvider);
    final List<BufferedChat> matches = ref
        .read(workflowControllerProvider(widget.workflow))
        .chat
        .where(
          (BufferedChat message) => message.messageId == messageId,
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      return;
    }
    _post(
      () => channel.postInput(
        workflowId: widget.workflow.workflowId,
        inputId: messageId,
        body: matches.first.body,
        destructive: _destructiveInputs[messageId] ?? false,
      ),
    );
  }

  String _nextInputId() {
    _inputCount += 1;
    return '${widget.workflow.workflowId}-in$_inputCount';
  }

  /// The agent channel is synchronous, so every send leaves the current
  /// frame and lands in its own event turn.
  void _post(void Function() send) {
    if (_sendError.isNotEmpty) {
      setState(() {
        _sendError = '';
      });
    }
    Future<void>(() {
      try {
        send();
      } on Object catch (error) {
        _reportError(error);
      }
    });
  }

  void _reportError(Object error) {
    if (!mounted) {
      return;
    }
    setState(() {
      _sendError = '$error';
    });
  }
}
