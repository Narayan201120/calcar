import 'package:calcar/screens/workflow/workflow_models.dart';
import 'package:flutter/material.dart';

/// Remaining-time label for a pending approval. Past expiry reads Expired.
String approvalCountdown(int expiresAtMillis, int nowMillis) {
  final int secs = ((expiresAtMillis - nowMillis) / 1000).ceil();
  if (secs <= 0) {
    return 'Expired';
  }
  final int minutes = secs ~/ 60;
  final int rest = secs % 60;
  if (minutes > 0) {
    return 'Expires in ${minutes}m ${rest}s';
  }
  return 'Expires in ${rest}s';
}

/// Approval card with countdown. Renders inert after expiry or resolve:
/// both action buttons disable and no resend affordance ever appears.
/// Single resolve wins upstream; this widget only reports taps.
class ApprovalCard extends StatelessWidget {
  final ApprovalRequest approval;
  final int nowMillis;
  final void Function(String approvalId, bool approved)? onResolve;

  const ApprovalCard({
    super.key,
    required this.approval,
    required this.nowMillis,
    this.onResolve,
  });

  bool get _resolved => approval.resolution != null;
  bool get _expired =>
      !_resolved && approval.expiresAtMillis <= nowMillis;
  bool get _inert => _resolved || _expired;

  String _stateText() {
    if (approval.resolution != null) {
      return 'Resolved: ${approval.resolution}';
    }
    return approvalCountdown(approval.expiresAtMillis, nowMillis);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('approval-${approval.approvalId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              approval.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(approval.detail),
            const SizedBox(height: 4),
            Text(
              _stateText(),
              key: ValueKey('approval-state-${approval.approvalId}'),
            ),
            if (approval.destructive && !_inert)
              const Text('Destructive action'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                FilledButton(
                  key: ValueKey('approve-${approval.approvalId}'),
                  onPressed: _inert
                      ? null
                      : () => onResolve?.call(approval.approvalId, true),
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: ValueKey('reject-${approval.approvalId}'),
                  onPressed: _inert
                      ? null
                      : () => onResolve?.call(approval.approvalId, false),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
