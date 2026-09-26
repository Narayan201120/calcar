// Workflow buffer state: snapshot first, live deltas after.
//
// Ordering: deltas carry the per-workflow monotonic seq from the agent
// event stream. Anything at or below [WorkflowBuffers.lastSeqNo] is
// stale or duplicate and dropped, and anything before the snapshot is
// dropped. Disconnect freezes the buffers: while frozen every delta is
// dropped, resolve attempts fail, and the connection banner owns the UI.
// Caps from caps.dart hold on every insert: chat 300, activity 500,
// terminal 2000 lines or 256 KB, diffs 50 files or 200 KB.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'caps.dart';
import 'models.dart';
import 'snapshot_source.dart';

class WorkflowController extends StateNotifier<WorkflowBuffers> {
  WorkflowController(this._source, this.computerId, this.workflowId)
      : super(
          WorkflowBuffers.empty(
            computerId: computerId,
            workflowId: workflowId,
          ),
        );

  final SnapshotSource _source;
  final String computerId;
  final String workflowId;

  bool _snapshotLoaded = false;
  bool _frozen = false;
  String _loadError = '';

  bool get snapshotLoaded => _snapshotLoaded;

  bool get frozen => _frozen;

  String get loadError => _loadError;

  /// Snapshot fetch. Unfreezes on success: a refetch after reconnect is
  /// the only thing that clears the freeze.
  Future<bool> loadSnapshot() async {
    try {
      final WorkflowBuffers snap =
          await _source.fetchWorkflow(computerId, workflowId);
      _snapshotLoaded = true;
      _frozen = false;
      _loadError = '';
      state = snap.capped();
      return true;
    } on Object catch (e) {
      _loadError = '$e';
      return false;
    }
  }

  /// Merge step calls this from a connection listener: true on drop
  /// (freeze), false only via [loadSnapshot] after reconnect.
  void setFrozen({required bool frozen}) {
    _frozen = frozen;
  }

  bool _accept(int seqNo) {
    if (!_snapshotLoaded || _frozen) {
      return false;
    }
    return seqNo > state.lastSeqNo;
  }

  void applyStatus({required int seqNo, required String status}) {
    if (!_accept(seqNo)) {
      return;
    }
    state = state.copyWith(status: status, lastSeqNo: seqNo);
  }

  void appendActivity(BufferedActivity event) {
    if (!_accept(event.seqNo)) {
      return;
    }
    state = state.copyWith(
      activity: tailOf<BufferedActivity>(
        <BufferedActivity>[...state.activity, event],
        kActivityCap,
      ),
      lastSeqNo: event.seqNo,
    );
  }

  void appendChat(BufferedChat message) {
    if (!_accept(message.seqNo)) {
      return;
    }
    state = state.copyWith(
      chat: tailOf<BufferedChat>(
        <BufferedChat>[...state.chat, message],
        kChatCap,
      ),
      lastSeqNo: message.seqNo,
    );
  }

  void appendTerminal({required int seqNo, required List<String> lines}) {
    if (lines.isEmpty || !_accept(seqNo)) {
      return;
    }
    state = state.copyWith(
      terminalLines: capTerminalTail(
        <String>[...state.terminalLines, ...lines],
      ),
      terminalTotalLines: state.terminalTotalLines + lines.length,
      lastSeqNo: seqNo,
    );
  }

  void applyFiles({required int seqNo, required List<BufferedFile> hunks}) {
    if (!_accept(seqNo)) {
      return;
    }
    final List<BufferedFile> kept = capDiffs(hunks);
    state = state.copyWith(
      files: kept,
      filesTruncated: diffsTruncated(kept, hunks.length),
      lastSeqNo: seqNo,
    );
  }

  void upsertApproval({
    required int seqNo,
    required TrackedApproval approval,
  }) {
    if (!_accept(seqNo)) {
      return;
    }
    final List<TrackedApproval> next = state.approvals
        .where(
          (TrackedApproval current) =>
              current.approvalId != approval.approvalId,
        )
        .toList(growable: false);
    next.add(approval);
    state = state.copyWith(
      approvals: List<TrackedApproval>.unmodifiable(next),
      lastSeqNo: seqNo,
    );
  }

  /// Local resolve marking. Returns false without recording anything
  /// when the approval is unknown, frozen, expired, or already resolved:
  /// expired approvals are never resendable and a single resolve wins.
  /// The transport send with the idempotency key is merge-step work.
  bool resolveApproval(
    String approvalId, {
    required bool approved,
    required int nowMillis,
  }) {
    if (_frozen) {
      return false;
    }
    final int index = state.approvals.indexWhere(
      (TrackedApproval current) => current.approvalId == approvalId,
    );
    if (index < 0) {
      return false;
    }
    final TrackedApproval current = state.approvals[index];
    if (!current.canResolve(nowMillis)) {
      return false;
    }
    final List<TrackedApproval> next =
        List<TrackedApproval>.from(state.approvals);
    next[index] =
        current.withResolution(approved ? 'approved' : 'rejected');
    state = state.copyWith(
      approvals: List<TrackedApproval>.unmodifiable(next),
    );
    return true;
  }
}
