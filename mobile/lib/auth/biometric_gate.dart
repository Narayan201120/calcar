// Biometric gate over local_auth. One method, no platform channel
// wiring: the plugin owns the OS dialog, this file owns the result
// mapping. API 23 reality is documented, not hidden: fingerprint only,
// no unified prompt, still a real hardware gate where enrolled.
// Unavailable is a hard refusal downstream, never a silent allow.
library;

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'package:calcar/screens/first_run.dart';

/// Maps a platform auth attempt to the app result. Pure and fully
/// tested: the widget tree and the OS dialog are the only untested
/// parts, and both belong to their owners.
LocalAuthResult classifyAttempt({required bool? authenticated, Object? error}) {
  if (error != null) {
    return _classifyError(error);
  }
  return authenticated == true ? LocalAuthResult.unlocked : LocalAuthResult.failed;
}

LocalAuthResult _classifyError(Object error) {
  if (error is! PlatformException) {
    return LocalAuthResult.failed;
  }
  switch (error.code) {
    case 'UserCancel':
    case 'SystemCancel':
      return LocalAuthResult.cancelled;
    case 'NotAvailable':
    case 'NotEnrolled':
    case 'PasscodeNotSet':
    case 'BiometricNeeded':
      return LocalAuthResult.unavailable;
    case 'LockedOut':
    case 'PermanentlyLockedOut':
    default:
      return LocalAuthResult.failed;
  }
}

/// The production gate. Prompts with the caller reason, checks
/// enrollment first so a confusing OS dialog never appears.
class BiometricGate implements LocalAuthGate {
  BiometricGate({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<LocalAuthResult> authenticate({required String reason}) async {
    try {
      if (!await _auth.canCheckBiometrics) {
        return LocalAuthResult.unavailable;
      }
      final bool ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true),
      );
      return classifyAttempt(authenticated: ok);
    } on Object catch (error) {
      return classifyAttempt(authenticated: false, error: error);
    }
  }
}
