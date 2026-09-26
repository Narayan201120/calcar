import 'package:calcar/api/models.dart';
import 'package:flutter/material.dart';

/// Device management: trusted phones and managed computers with name,
/// id, type, state, last seen, and the Owner badge.
///
/// Render plus optimistic UI only: [devices], [presenceById], and
/// [ownerDeviceId] arrive through the constructor, effects leave through
/// callbacks. This widget never touches providers, state, or API clients.
///
/// Revoke contract: the caller must complete fresh re-auth inside
/// [onRevoke] before the backend call. The row is removed optimistically
/// and restored (rolled back) when [onRevoke] returns false or throws;
/// [onRollback] is then notified so the merge step can surface it.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({
    super.key,
    required this.devices,
    required this.presenceById,
    required this.ownerDeviceId,
    required this.onRevoke,
    this.onRollback,
  });

  /// All known devices. Roles mirror the backend `role` field verbatim.
  final List<Device> devices;

  /// Presence keyed by device id. Missing entries render as never seen.
  final Map<String, Presence> presenceById;

  /// Device id of the Owner phone. Badged and never revocable here.
  final String ownerDeviceId;

  /// Fresh re-auth plus backend revoke. True keeps the removal,
  /// false (or throw) rolls it back.
  final Future<bool> Function(Device device) onRevoke;

  /// Notified with the device whose optimistic removal was rolled back.
  final ValueChanged<Device>? onRollback;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  /// Optimistically removed ids. Dropped on success, restored on failure.
  final Set<String> _removedIds = <String>{};

  List<Device> get _visible {
    return widget.devices
        .where((Device device) => !_removedIds.contains(device.deviceId))
        .toList();
  }

  bool _isOwner(Device device) {
    return device.deviceId == widget.ownerDeviceId ||
        device.role.toLowerCase() == 'owner';
  }

  bool _isPhone(Device device) {
    return _isOwner(device) || device.role.toLowerCase().contains('phone');
  }

  String _stateOf(Device device) {
    if (device.revoked) {
      return 'revoked';
    }
    final Presence? presence = widget.presenceById[device.deviceId];
    if (presence != null && presence.online) {
      return 'online';
    }
    return 'offline';
  }

  String _lastSeenOf(Device device) {
    final Presence? presence = widget.presenceById[device.deviceId];
    if (presence == null || presence.lastSeenMillis <= 0) {
      return 'never';
    }
    return DateTime.fromMillisecondsSinceEpoch(
      presence.lastSeenMillis,
      isUtc: true,
    ).toIso8601String();
  }

  Future<void> _revoke(Device device) async {
    setState(() {
      _removedIds.add(device.deviceId);
    });
    bool ok = false;
    try {
      ok = await widget.onRevoke(device);
    } catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      if (!ok) {
        _removedIds.remove(device.deviceId);
      }
    });
    if (!ok) {
      widget.onRollback?.call(device);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Device> visible = _visible;
    final List<Device> phones =
        visible.where(_isPhone).toList();
    final List<Device> computers =
        visible.where((Device device) => !_isPhone(device)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: visible.isEmpty
          ? const Center(child: Text('No devices yet'))
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Trusted phones'),
                ),
                if (phones.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('No trusted phones'),
                  ),
                for (final Device device in phones) _row(device),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Managed computers'),
                ),
                if (computers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('No managed computers'),
                  ),
                for (final Device device in computers) _row(device),
              ],
            ),
    );
  }

  Widget _row(Device device) {
    final bool owner = _isOwner(device);
    final bool revocable = !owner && !device.revoked;
    return ListTile(
      key: Key('device-${device.deviceId}'),
      title: Row(
        children: [
          Expanded(child: Text(device.displayName)),
          if (owner)
            Container(
              key: Key('owner-badge-${device.deviceId}'),
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                border: Border.all(),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Owner'),
            ),
        ],
      ),
      subtitle: Text(
        'ID: ${device.deviceId}\n'
        'Type: ${device.role}\n'
        'State: ${_stateOf(device)}\n'
        'Last seen: ${_lastSeenOf(device)}',
      ),
      isThreeLine: true,
      trailing: revocable
          ? TextButton(
              key: Key('revoke-${device.deviceId}'),
              onPressed: () => _revoke(device),
              child: const Text('Revoke'),
            )
          : null,
    );
  }
}
