import 'package:calcar/auth/biometric_gate.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('attempt classification', () {
    test(
      'contract: a successful prompt unlocks',
      () {
        expect(
          classifyAttempt(authenticated: true),
          LocalAuthResult.unlocked,
        );
      },
    );

    test(
      'contract: a failed prompt stays locked without error',
      () {
        expect(
          classifyAttempt(authenticated: false),
          LocalAuthResult.failed,
        );
      },
    );

    test(
      'contract: user dismissal cancels instead of failing',
      () {
        for (final String code in <String>['UserCancel', 'SystemCancel']) {
          expect(
            classifyAttempt(
              authenticated: false,
              error: PlatformException(code: code),
            ),
            LocalAuthResult.cancelled,
          );
        }
      },
    );

    test(
      'contract: missing biometrics is unavailable, a hard refusal',
      () {
        for (final String code in <String>[
          'NotAvailable',
          'NotEnrolled',
          'PasscodeNotSet',
          'BiometricNeeded',
        ]) {
          expect(
            classifyAttempt(
              authenticated: false,
              error: PlatformException(code: code),
            ),
            LocalAuthResult.unavailable,
          );
        }
      },
    );

    test(
      'contract: lockout and unknown errors fail closed',
      () {
        for (final Object error in <Object>[
          PlatformException(code: 'LockedOut'),
          PlatformException(code: 'PermanentlyLockedOut'),
          PlatformException(code: 'SomethingNew'),
          StateError('not a platform error'),
        ]) {
          expect(
            classifyAttempt(authenticated: false, error: error),
            LocalAuthResult.failed,
          );
        }
      },
    );
  });
}
