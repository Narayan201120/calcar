// Computer snapshot state: one header plus workflow rows per computer.
// Snapshot first, header deltas after. Status chips derive from the row
// statuses in screens/computer_detail.dart and are never stored.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'snapshot_source.dart';

class ComputerState {
  final ComputerSnapshot? snapshot;
  final bool loading;
  final String error;

  const ComputerState({this.snapshot, required this.loading, this.error = ''});

  factory ComputerState.initial() {
    return const ComputerState(loading: false);
  }

  ComputerState copyWith({
    ComputerSnapshot? snapshot,
    bool? loading,
    String? error,
  }) {
    return ComputerState(
      snapshot: snapshot ?? this.snapshot,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class ComputerController extends StateNotifier<ComputerState> {
  ComputerController(this._source, this.computerId)
      : super(ComputerState.initial());

  final SnapshotSource _source;
  final String computerId;

  bool get snapshotLoaded => state.snapshot != null;

  /// One snapshot fetch for this computer. Rejects snapshots addressed
  /// to another computer instead of mixing rows across machines.
  Future<bool> refresh() async {
    state = state.copyWith(loading: true, error: '');
    try {
      final ComputerSnapshot snap = await _source.fetchComputer(computerId);
      if (snap.deviceId != computerId) {
        state = state.copyWith(
          loading: false,
          error: 'wrong computer snapshot',
        );
        return false;
      }
      state = ComputerState(snapshot: snap, loading: false);
      return true;
    } on Object catch (e) {
      state = state.copyWith(loading: false, error: '$e');
      return false;
    }
  }

  /// Header delta from presence.changed. Dropped before the snapshot.
  void applyPresence({required bool online, required int lastSeenMillis}) {
    final ComputerSnapshot? snap = state.snapshot;
    if (snap == null) {
      return;
    }
    state = state.copyWith(
      snapshot: ComputerSnapshot(
        deviceId: snap.deviceId,
        displayName: snap.displayName,
        online: online,
        lastSeenMillis: lastSeenMillis,
        workflows: snap.workflows,
      ),
    );
  }

  /// Row delta patching one workflow status. Dropped before the
  /// snapshot; seq ordering lives one level down in WorkflowController.
  void applyWorkflowStatus(String workflowId, String status) {
    final ComputerSnapshot? snap = state.snapshot;
    if (snap == null) {
      return;
    }
    final List<WorkflowRow> next = snap.workflows
        .map(
          (WorkflowRow row) {
            if (row.workflowId != workflowId) {
              return row;
            }
            return WorkflowRow(
              workflowId: row.workflowId,
              computerId: row.computerId,
              title: row.title,
              status: status,
            );
          },
        )
        .toList(growable: false);
    state = state.copyWith(
      snapshot: ComputerSnapshot(
        deviceId: snap.deviceId,
        displayName: snap.displayName,
        online: snap.online,
        lastSeenMillis: snap.lastSeenMillis,
        workflows: List<WorkflowRow>.unmodifiable(next),
      ),
    );
  }
}
