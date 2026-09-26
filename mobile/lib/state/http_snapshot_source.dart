// HTTP snapshot source: the one place the snapshot-first state layer
// touches the network.
//
// Devices, presence, and the Owner id come from CalcarApiClient against
// the P3 backend. The computer header, its workflow rows, and the capped
// workflow buffers come from AgentChannelClient over the mesh channel,
// because workflow state never rides the backend. Every method here is
// one logical fetch: the controllers apply a whole snapshot or a live
// delta, never a blend of the two.
//
// Presence is the only fan-out. The backend has no bulk presence
// endpoint, only GET /v1/computers/{id}/presence per device, so a device
// with no stored record (404 NO_PRESENCE) is a normal answer and drops
// out of the map instead of failing the snapshot. A gap in the map
// already reads as offline through deviceStateOf in models.dart.
import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/api/api_error.dart';
import 'package:calcar/api/client.dart';
import 'package:calcar/api/models.dart';

import 'models.dart';
import 'snapshot_source.dart';

/// Backend code for a presence lookup with no stored record. The store
/// has no row for a device that never heartbeated, and the backend
/// answers 404 with this code. Not an ApiCodes member: no spec table
/// covers it, and the fallback code for a bare 404 is UNKNOWN_SESSION,
/// which would name the wrong thing entirely.
const String _noPresence = 'NO_PRESENCE';

class HttpSnapshotSource implements SnapshotSource {
  HttpSnapshotSource({required this.api, required this.agent});

  /// P3 control plane. Devices, presence, and the Owner id.
  final CalcarApiClient api;

  /// Authenticated mesh channel to the managed computer. Headers,
  /// workflow rows, and capped buffers.
  final AgentChannelClient agent;

  /// Device list from the last successful [fetchDevices], reused by
  /// [fetchPresence] and [fetchOwnerDeviceId] so one pull refresh costs
  /// one /v1/devices call instead of three. Held together with the
  /// bearer token it was fetched under, so a re-login can never derive
  /// state from the previous session's rows.
  List<Device>? _devices;
  String? _devicesToken;

  @override
  Future<List<Device>> fetchDevices() async {
    final List<Device> devices = await api.listDevices();
    _devices = devices;
    _devicesToken = api.token;
    return devices;
  }

  @override
  Future<Map<String, Presence>> fetchPresence() async {
    final List<Device> devices = await _knownDevices();
    final List<MapEntry<String, Presence?>> replies =
        await Future.wait<MapEntry<String, Presence?>>(
      devices.map(
        (Device device) async {
          final Presence? presence = await _presenceFor(device.deviceId);
          return MapEntry<String, Presence?>(device.deviceId, presence);
        },
      ),
    );
    final Map<String, Presence> byId = <String, Presence>{};
    for (final MapEntry<String, Presence?> reply in replies) {
      final Presence? presence = reply.value;
      if (presence != null) {
        byId[reply.key] = presence;
      }
    }
    return byId;
  }

  @override
  Future<String> fetchOwnerDeviceId() async {
    final List<Device> devices = await _knownDevices();
    for (final Device device in devices) {
      // An empty owner id leaves the owner role strings as the only
      // test inside isOwnerDevice, which is what a derivation from the
      // device list can offer. First match wins, matching the backend
      // rule that one phone per user holds the owner role.
      if (isOwnerDevice(device, '')) {
        return device.deviceId;
      }
    }
    return '';
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    // The agent channel is synchronous transport, so the call goes
    // through Future.sync: an agent failure has to arrive as a rejected
    // Future for the controllers to catch, not as a throw into the
    // caller's own stack.
    return Future<ComputerSnapshot>.sync(
      () => agent.fetchComputer(computerId),
    );
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    return Future<WorkflowBuffers>.sync(
      () => agent.fetchWorkflow(computerId, workflowId),
    );
  }

  /// Device list for [fetchPresence] and [fetchOwnerDeviceId]: the one
  /// [fetchDevices] already returned under the current token, else a
  /// fresh fetch.
  Future<List<Device>> _knownDevices() {
    final List<Device>? devices = _devices;
    if (devices != null && _devicesToken == api.token) {
      return Future<List<Device>>.value(devices);
    }
    return fetchDevices();
  }

  /// One presence record, or null when the store has none. A reply
  /// addressed to a different device is dropped as well: a crossed
  /// response must never be filed under the id that was asked for.
  Future<Presence?> _presenceFor(String deviceId) async {
    try {
      final Presence presence = await api.getPresence(deviceId);
      if (presence.deviceId.isNotEmpty && presence.deviceId != deviceId) {
        return null;
      }
      return presence;
    } on ApiException catch (e) {
      if (e.code == _noPresence || e.status == 404) {
        return null;
      }
      rethrow;
    }
  }
}

/// The app shell's override for snapshotSourceProvider: one source with
/// both transports wired. Pass a client when the shell already holds one
/// and wants to own its lifetime; the missing side is built from its
/// base url and the bearer token, which the mesh channel shares with the
/// backend client. Either base url may carry a trailing slash.
SnapshotSource buildHttpSnapshotSource({
  required String apiBaseUrl,
  required String agentBaseUrl,
  required String token,
  CalcarApiClient? apiClient,
  AgentChannelClient? agentClient,
}) {
  return HttpSnapshotSource(
    api: apiClient ?? CalcarApiClient(baseUrl: apiBaseUrl, token: token),
    agent: agentClient ??
        AgentChannelClient(baseUrl: agentBaseUrl, token: token),
  );
}
