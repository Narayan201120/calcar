// Snapshot fetch contracts for the state layer.
//
// The merge step implements this with CalcarApiClient plus the agent
// snapshot endpoint over the authenticated channel. State tests override
// [snapshotSourceProvider] with canned data, so no test touches the
// network. One method equals one logical snapshot fetch.
import 'package:calcar/api/models.dart';

import 'models.dart';

abstract class SnapshotSource {
  /// One snapshot fetch for pull refresh on My Computers.
  Future<List<Device>> fetchDevices();

  /// Presence map keyed by device id, fetched with the device snapshot.
  Future<Map<String, Presence>> fetchPresence();

  /// Id of the Owner phone. Badged in the device list, never revocable.
  Future<String> fetchOwnerDeviceId();

  /// One snapshot fetch for a computer header plus its workflow rows.
  Future<ComputerSnapshot> fetchComputer(String computerId);

  /// One snapshot fetch for full workflow buffers. Deltas apply only
  /// after this snapshot lands (see WorkflowController).
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  );
}
