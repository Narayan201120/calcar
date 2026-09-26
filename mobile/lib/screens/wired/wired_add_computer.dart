// Add Computer wired to the control-plane pairing calls.
//
// The session state lives in [addComputerControllerProvider], one flow
// per id, dropped when the last viewer navigates away. That is what
// makes the session single use: leaving the screen drops it, and the
// next entry starts at create with a new id, so a consumed or expired
// session is never reused.
import 'dart:async';

import 'package:calcar/screens/add_computer.dart';
import 'package:calcar/screens/wired/add_computer_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Seconds between countdown repaints and TTL checks.
const Duration _tickInterval = Duration(seconds: 1);

class WiredAddComputerScreen extends ConsumerStatefulWidget {
  /// Hardware-backed signer for the approve path. Without one, approve
  /// is refused with a reason and reject still works: a grant is never
  /// signed by anything but the Owner key.
  final PairingSigner? signer;

  /// Flow identity, which also namespaces this flow's idempotency keys.
  /// Give each entry a fresh id to guarantee a fresh session.
  final String flowId;

  const WiredAddComputerScreen({
    super.key,
    this.signer,
    this.flowId = 'add-computer',
  });

  @override
  ConsumerState<WiredAddComputerScreen> createState() =>
      _WiredAddComputerScreenState();
}

class _WiredAddComputerScreenState
    extends ConsumerState<WiredAddComputerScreen> {
  /// Repaints the countdown and checks the TTL once a second.
  Timer? _ticker;

  int _nowMillis = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_tickInterval, (Timer _) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  void _tick() {
    if (!mounted) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final AddComputerController controller = ref.read(
      addComputerControllerProvider(widget.flowId).notifier,
    );
    controller.tick(now);
    // Repaint so the countdown moves. The tick only changes state when
    // the TTL runs out, and the watch already covers that.
    setState(() {
      _nowMillis = now;
    });
  }

  @override
  Widget build(BuildContext context) {
    _reportErrors();
    final AddComputerState state =
        ref.watch(addComputerControllerProvider(widget.flowId));
    final AddComputerController controller =
        ref.read(addComputerControllerProvider(widget.flowId).notifier);
    final bool idle = !state.busy && !state.deciding;
    return AddComputerScreen(
      stage: state.stage,
      sessionId: state.sessionId.isEmpty ? null : state.sessionId,
      qrNonce: state.qrNonce.isEmpty ? null : state.qrNonce,
      remaining: _remaining(state),
      joinDisplayName: state.join?.displayName,
      joinFingerprint: state.join?.fingerprint,
      joinRequestId: state.join?.requestId,
      onCreateSession: idle
          ? () => unawaited(controller.createSession())
          : null,
      onApprove: state.stage == AddComputerStage.waiting
          ? () => unawaited(
                controller.decide(approve: true, signer: widget.signer),
              )
          : null,
      onReject: state.stage == AddComputerStage.waiting
          ? () => unawaited(
                controller.decide(approve: false, signer: widget.signer),
              )
          : null,
      onRegenerate: idle
          ? () => unawaited(controller.createSession())
          : null,
    );
  }

  /// The pure screen has nowhere to put an error, so a failure rides a
  /// snack bar. It never blocks a stage: the Owner decides whether to
  /// retry from the same card.
  void _reportErrors() {
    ref.listen<AddComputerState>(
      addComputerControllerProvider(widget.flowId),
      (AddComputerState? previous, AddComputerState next) {
        if (next.error.isEmpty || next.error == previous?.error) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(next.error)),
        );
      },
    );
  }

  Duration _remaining(AddComputerState state) {
    if (state.expiresAtMillis == 0) {
      return Duration.zero;
    }
    final int millis = state.expiresAtMillis - _nowMillis;
    return millis > 0 ? Duration(milliseconds: millis) : Duration.zero;
  }
}
