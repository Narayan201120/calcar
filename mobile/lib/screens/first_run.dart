/// First run: Owner establish, then the biometric lock, then the empty
/// list. Three stages and no way back, because PLAN P2 makes the first
/// trusted phone the Owner and PLAN P6 makes a normal open need a fresh
/// local auth.
///
/// [LocalAuthGate] is the only seam and it is an interface on purpose.
/// No method channel is wired here: the merge step passes the local_auth
/// backed gate, tests pass a fake. A cancelled or failed prompt leaves
/// the phone locked, and a phone with nothing enrolled is told so
/// instead of being stuck.
library;

import 'package:calcar/screens/computers.dart';
import 'package:flutter/material.dart';

/// Outcome of one local auth prompt. Every failure is a value, so a
/// missing plugin or a denied prompt cannot crash the lock screen.
enum LocalAuthResult {
  /// The device owner authenticated. The screen may open.
  unlocked,

  /// The prompt was dismissed. The phone stays locked, with no error:
  /// a cancel is a decision, not a fault.
  cancelled,

  /// The prompt could not run. The phone stays locked and says so.
  failed,

  /// No biometric or device credential is enrolled, so there is nothing
  /// to prompt with. The screen offers continuing without a lock, because
  /// a phone with no screen lock at all must still be able to open the
  /// control panel.
  unavailable,
}

/// The lock in front of the app.
///
/// Implementations report their own failures as results rather than
/// throwing, and the reason string is shown by the platform sheet, never
/// logged.
abstract class LocalAuthGate {
  /// Prompts the device owner for a local auth, biometric or device
  /// credential, whatever the platform offers.
  Future<LocalAuthResult> authenticate({required String reason});
}

/// Stages of the first run flow, forward only.
enum FirstRunStage {
  /// Collect the Owner display name and create the Owner.
  ownerEstablish,

  /// The Owner exists. The phone is locked until the gate opens it.
  locked,

  /// Unlocked. The app shows the empty list.
  ready,
}

/// First run screen.
///
/// [onEstablishOwner] creates the Owner: the merge step generates the
/// hardware backed key and calls bootstrapOwner, and returns false when
/// that failed. A failed setup never reaches the lock and never prompts,
/// so a half established Owner cannot leave the phone open.
class FirstRunScreen extends StatefulWidget {
  final Future<bool> Function(String displayName) onEstablishOwner;
  final LocalAuthGate gate;

  const FirstRunScreen({
    super.key,
    required this.onEstablishOwner,
    required this.gate,
  });

  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends State<FirstRunScreen> {
  final TextEditingController _name = TextEditingController();

  FirstRunStage _stage = FirstRunStage.ownerEstablish;
  bool _busy = false;
  String _error = '';
  bool _noLockEnrolled = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _establish() async {
    final String displayName = _name.text.trim();
    if (_busy) {
      return;
    }
    if (displayName.isEmpty) {
      setState(() {
        _error = 'Name required';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    bool ok = false;
    try {
      ok = await widget.onEstablishOwner(displayName);
    } on Object catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      if (ok) {
        _stage = FirstRunStage.locked;
      } else {
        _error = 'Owner setup failed';
      }
    });
  }

  Future<void> _unlock() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    LocalAuthResult result;
    try {
      result = await widget.gate.authenticate(reason: 'Unlock Calcar');
    } on Object catch (_) {
      result = LocalAuthResult.failed;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _noLockEnrolled = result == LocalAuthResult.unavailable;
      if (result == LocalAuthResult.unlocked) {
        _stage = FirstRunStage.ready;
        _error = '';
      } else if (result == LocalAuthResult.failed) {
        _error = 'Unlock failed';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case FirstRunStage.ownerEstablish:
        return _ownerForm();
      case FirstRunStage.locked:
        return _lock();
      case FirstRunStage.ready:
        return const ComputersScreen();
    }
  }

  Widget _ownerForm() {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up Calcar')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'This phone becomes the Owner. It is the only device that '
              'can approve a computer.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('first-run-owner-name'),
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Your name',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('first-run-owner-submit'),
              onPressed: _busy ? null : _establish,
              child: const Text('Create Owner'),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error.isNotEmpty)
              Text(
                _error,
                key: const ValueKey('first-run-owner-error'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _lock() {
    return Scaffold(
      appBar: AppBar(title: const Text('Locked')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Calcar is locked. Confirm it is you.'),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('first-run-unlock'),
              onPressed: _busy ? null : _unlock,
              child: const Text('Unlock'),
            ),
            if (_noLockEnrolled) ...<Widget>[
              const SizedBox(height: 12),
              const Text(
                'No screen lock is set on this phone, so there is '
                'nothing to confirm against.',
              ),
              TextButton(
                key: const ValueKey('first-run-continue-unlocked'),
                onPressed: _busy
                    ? null
                    : () {
                        setState(() {
                          _stage = FirstRunStage.ready;
                        });
                      },
                child: const Text('Continue without a lock'),
              ),
            ],
            if (_error.isNotEmpty)
              Text(
                _error,
                key: const ValueKey('first-run-lock-error'),
              ),
          ],
        ),
      ),
    );
  }
}
