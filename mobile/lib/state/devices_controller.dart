// Device list state: one snapshot fetch per pull refresh, live
// presence and revocation deltas after. Phones versus computers
// grouping, the Owner badge, and online state all derive from this
// state via the helpers in models.dart and are never stored.
import 'package:calcar/api/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'snapshot_source.dart';

class DevicesState {
  final List<Device> devices;
  final Map<String, Presence> presenceById;
  final String ownerDeviceId;
  final bool loading;
  final String error;

  const DevicesState({
    required this.devices,
    required this.presenceById,
    required this.ownerDeviceId,
    required this.loading,
    this.error = '',
  });

  factory DevicesState.initial() {
    return const DevicesState(
      devices: <Device>[],
      presenceById: <String, Presence>{},
      ownerDeviceId: '',
      loading: false,
    );
  }

  DevicesState copyWith({
    List<Device>? devices,
    Map<String, Presence>? presenceById,
    String? ownerDeviceId,
    bool? loading,
    String? error,
  }) {
    return DevicesState(
      devices: devices ?? this.devices,
      presenceById: presenceById ?? this.presenceById,
      ownerDeviceId: ownerDeviceId ?? this.ownerDeviceId,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }

  List<Device> get phones =>
      devices.where(isPhoneDevice).toList(growable: false);

  List<Device> get computers => devices
      .where((Device device) => !isPhoneDevice(device))
      .toList(growable: false);
}

class DevicesController extends StateNotifier<DevicesState> {
  DevicesController(this._source) : super(DevicesState.initial());

  final SnapshotSource _source;

  /// Pull refresh: one snapshot fetch replacing the whole list.
  /// Presence arrives with the same refresh; the Owner id is fetched
  /// once and then kept.
  Future<void> refresh() async {
    state = state.copyWith(loading: true, error: '');
    try {
      final List<Device> devices = await _source.fetchDevices();
      final Map<String, Presence> presence = await _source.fetchPresence();
      String ownerId = state.ownerDeviceId;
      if (ownerId.isEmpty) {
        ownerId = await _source.fetchOwnerDeviceId();
      }
      state = state.copyWith(
        devices: List<Device>.unmodifiable(devices),
        presenceById: Map<String, Presence>.unmodifiable(presence),
        ownerDeviceId: ownerId,
        loading: false,
      );
    } on Object catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  /// Live delta from presence.changed. Malformed events never reach
  /// here; the binding filters them first.
  void applyPresenceChanged(
    String deviceId, {
    required bool online,
    required int lastSeenMillis,
  }) {
    final Map<String, Presence> next =
        Map<String, Presence>.from(state.presenceById);
    next[deviceId] = Presence(
      deviceId: deviceId,
      online: online,
      lastSeenMillis: lastSeenMillis,
    );
    state = state.copyWith(
      presenceById: Map<String, Presence>.unmodifiable(next),
    );
  }

  /// Live delta from trust.revoked. Marks the row revoked in place so
  /// the derived state flips to revoked and the revoke button drops.
  void applyTrustRevoked(String deviceId) {
    bool changed = false;
    final List<Device> next = state.devices
        .map(
          (Device device) {
            if (device.deviceId != deviceId || device.revoked) {
              return device;
            }
            changed = true;
            return Device(
              deviceId: device.deviceId,
              role: device.role,
              displayName: device.displayName,
              pubkeyB64: device.pubkeyB64,
              fingerprint: device.fingerprint,
              revoked: true,
              authorizedBy: device.authorizedBy,
            );
          },
        )
        .toList(growable: false);
    if (changed) {
      state = state.copyWith(devices: List<Device>.unmodifiable(next));
    }
  }
}
