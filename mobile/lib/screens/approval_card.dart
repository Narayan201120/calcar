import 'package:flutter/material.dart';

/// Owner approve/reject card for one pairing join request.
///
/// Render only: every field arrives through the constructor and the
/// decision leaves through [onApprove]/[onReject]. This widget never
/// touches providers, state, or API clients.
///
/// Inert rule: when [expired] or [resolved] is true both buttons render
/// disabled, so a decision can never fire twice and an expired approval
/// is never resendable.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.deviceName,
    required this.deviceId,
    required this.fingerprint,
    required this.requestTime,
    required this.remaining,
    required this.expired,
    required this.resolved,
    this.resolution,
    this.onApprove,
    this.onReject,
  });

  /// Exact PC name from the join request.
  final String deviceName;

  /// Display and routing only, never proof.
  final String deviceId;

  /// Exact fingerprint from the join request.
  final String fingerprint;

  /// When the PC submitted the join request.
  final DateTime requestTime;

  /// Time left before the pairing session TTL consumes the request.
  final Duration remaining;

  /// True once the session TTL has passed.
  final bool expired;

  /// True once a decision (or a remote resolve) has consumed the session.
  final bool resolved;

  /// Terminal label when [resolved] is true: `approved` or `rejected`.
  final String? resolution;

  /// Fires the Owner approve decision. Ignored while inert.
  final VoidCallback? onApprove;

  /// Fires the Owner reject decision. Ignored while inert.
  final VoidCallback? onReject;

  /// Inert once expired or resolved: no callback can fire from here.
  bool get isInert => expired || resolved;

  String _countdown() {
    if (expired) {
      return 'Expired';
    }
    final int totalSeconds = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
    final String minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return 'Expires in $minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deviceName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('Device ID: $deviceId'),
            Text('Fingerprint: $fingerprint'),
            Text(
              'Requested: ${requestTime.toIso8601String()}',
            ),
            const SizedBox(height: 8),
            Text(_countdown()),
            if (resolved && resolution != null) ...[
              const SizedBox(height: 4),
              Text('Resolved: $resolution'),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: isInert ? null : onApprove,
                    child: const Text('Approve'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: isInert ? null : onReject,
                    child: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
