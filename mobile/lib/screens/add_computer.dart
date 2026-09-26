import 'package:flutter/material.dart';

/// Single-use pairing flow stage. Sessions expire and cannot be reused,
/// so there is no transition back to an earlier stage.
enum AddComputerStage {
  /// Nothing created yet. Offers session creation.
  create,

  /// Session live, QR placeholder with countdown shown to be scanned.
  qr,

  /// PC join arrived. Shows the join card with approve/reject.
  waiting,

  /// Approve tapped, decision in flight. Buttons inert.
  approving,

  /// Reject tapped, decision in flight. Buttons inert.
  rejecting,

  /// TTL passed with no decision. Offers regenerate only, no reuse.
  expired,

  /// Session consumed by a decision. Terminal, no buttons, no reuse.
  done,
}

/// Add Computer: create session to QR placeholder with countdown to
/// waiting join card to approving/rejecting to expired/done.
///
/// Render only: all state arrives through the constructor, every
/// transition leaves through a callback. This widget never touches
/// providers, state, or API clients.
class AddComputerScreen extends StatelessWidget {
  const AddComputerScreen({
    super.key,
    required this.stage,
    this.sessionId,
    this.qrNonce,
    this.remaining = Duration.zero,
    this.joinDisplayName,
    this.joinFingerprint,
    this.joinRequestId,
    this.onCreateSession,
    this.onApprove,
    this.onReject,
    this.onRegenerate,
  });

  /// Current single-use stage of the pairing session.
  final AddComputerStage stage;

  /// Backend session id, present from [AddComputerStage.qr] on.
  final String? sessionId;

  /// Session reference carried by the QR. QR never equals trust.
  final String? qrNonce;

  /// Time left before the session TTL consumes it.
  final Duration remaining;

  /// PC display name from the join request, waiting stage on.
  final String? joinDisplayName;

  /// PC fingerprint from the join request, waiting stage on.
  final String? joinFingerprint;

  /// PC request id from the join request, waiting stage on.
  final String? joinRequestId;

  /// Starts a fresh pairing session.
  final VoidCallback? onCreateSession;

  /// Approves the waiting join request.
  final VoidCallback? onApprove;

  /// Rejects the waiting join request.
  final VoidCallback? onReject;

  /// Creates a brand-new session after expiry. Never reuses the old one.
  final VoidCallback? onRegenerate;

  String _countdown() {
    final int totalSeconds = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
    final String minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return 'Expires in $minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Computer')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (stage) {
      case AddComputerStage.create:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create a pairing session, then scan the QR from your PC.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onCreateSession,
              child: const Text('Create session'),
            ),
          ],
        );
      case AddComputerStage.qr:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scan this QR from your PC'),
            const SizedBox(height: 12),
            Container(
              key: const Key('qr-placeholder'),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                border: Border.all(),
              ),
              child: Text('QR: ${qrNonce ?? ''}'),
            ),
            const SizedBox(height: 8),
            if (sessionId != null) Text('Session: $sessionId'),
            Text(_countdown()),
          ],
        );
      case AddComputerStage.waiting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A computer wants to pair'),
            const SizedBox(height: 8),
            Text('Name: ${joinDisplayName ?? ''}'),
            Text('Fingerprint: ${joinFingerprint ?? ''}'),
            Text('Request: ${joinRequestId ?? ''}'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onApprove,
                    child: const Text('Approve'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onReject,
                    child: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ],
        );
      case AddComputerStage.approving:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Approving…'),
            SizedBox(height: 12),
            LinearProgressIndicator(),
          ],
        );
      case AddComputerStage.rejecting:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rejecting…'),
            SizedBox(height: 12),
            LinearProgressIndicator(),
          ],
        );
      case AddComputerStage.expired:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Session expired'),
            const SizedBox(height: 4),
            const Text(
              'Expired sessions cannot be reused. '
              'Generate a new one.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRegenerate,
              child: const Text('Regenerate'),
            ),
          ],
        );
      case AddComputerStage.done:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session used'),
            SizedBox(height: 4),
            Text(
              'This session is consumed and cannot be reused.',
            ),
          ],
        );
    }
  }
}
