// Device management wired to devicesControllerProvider, with the revoke
// effect on the control-plane client.
//
// The pure screen owns the optimistic removal and the rollback: it hides
// the row, calls [onRevoke], and puts the row back when that call
// returns false or throws. This wrapper only supplies the call, and it
// does not refetch afterwards: the authoritative state arrives with the
// live trust.revoked delta or with the next pull, and a refetch here
// would resurrect the row the Owner just removed.
import 'package:calcar/api/client.dart';
import 'package:calcar/api/models.dart';
import 'package:calcar/screens/devices.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WiredDevicesScreen extends ConsumerStatefulWidget {
  /// Fresh re-auth for this device, before the revoke is sent. The Owner
  /// key never leaves the hardware keystore, so the host owns this step
  /// and the wrapper refuses to revoke without it.
  final Future<void> Function(Device device) reauthenticate;

  /// Notified when an optimistic removal is rolled back, so the host can
  /// say why the device is still trusted.
  final ValueChanged<Device>? onRollback;

  const WiredDevicesScreen({
    super.key,
    required this.reauthenticate,
    this.onRollback,
  });

  @override
  ConsumerState<WiredDevicesScreen> createState() =>
      _WiredDevicesScreenState();
}

class _WiredDevicesScreenState extends ConsumerState<WiredDevicesScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred by a microtask: refresh sets provider state synchronously,
    // and a provider must never be modified while the tree is building.
    Future<void>.microtask(_load);
  }

  void _load() {
    ref.read(devicesControllerProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final DevicesState state = ref.watch(devicesControllerProvider);
    return DevicesScreen(
      devices: state.devices,
      presenceById: state.presenceById,
      ownerDeviceId: state.ownerDeviceId,
      onRevoke: _revoke,
      onRollback: widget.onRollback,
    );
  }

  /// True keeps the removal, false rolls it back. A failed re-auth, a
  /// revoked phone calling in, or a transport error all land on false,
  /// which is the one answer the pure screen understands.
  Future<bool> _revoke(Device device) async {
    // Read the client before the await: a disposed element may not use
    // its ref, and a missing override must fail before the Owner is
    // asked to re-auth for a call that cannot happen.
    final CalcarApiClient api = ref.read(apiClientProvider);
    try {
      await widget.reauthenticate(device);
      final RevokeResult result = await api.revokeDevice(
        device.deviceId,
        revokeIdempotencyKey(device.deviceId),
      );
      return result.revoked;
    } on Object catch (_) {
      return false;
    }
  }
}

/// Idempotency key for a revoke. Stable per device, so a retry after a
/// dropped response is the same request and not a second revocation.
String revokeIdempotencyKey(String deviceId) => 'revoke-$deviceId';
