import 'dart:convert';

import 'package:calcar/api/api.dart';
import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/onboarding/owner_setup.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Keys extends OwnerKeyService {
  _Keys() : super(store: _MapStore());

  final List<String> calls = <String>[];
  bool failGenerate = false;

  @override
  Future<void> generate() async {
    calls.add('generate');
    if (failGenerate) {
      throw StateError('secure element busy');
    }
    return super.generate();
  }

  @override
  Future<void> deleteKey() async {
    calls.add('delete');
    return super.deleteKey();
  }
}

class _MapStore implements SeedStore {
  final Map<String, String> backing = <String, String>{};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async {
    backing[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    backing.remove(key);
  }
}

class _Gate implements LocalAuthGate {
  _Gate(this.result);

  final LocalAuthResult result;
  int calls = 0;

  @override
  Future<LocalAuthResult> authenticate({required String reason}) async {
    calls += 1;
    return result;
  }
}

CalcarApiClient _api({required int status}) {
  return CalcarApiClient(
    baseUrl: 'https://backend.test',
    httpClient: MockClient((http.Request request) async {
      const String jsonMime = 'application/json';
      if (status >= 400) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'INVALID_INPUT',
            'retryable': false,
          }),
          status,
          headers: <String, String>{'Content-Type': jsonMime},
        );
      }
      final String path = request.url.path;
      if (path.endsWith('/v1/auth/challenge')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'device_id': 'PH-1',
            'challenge': 'ch-abc-123',
            'expires_in_seconds': 120,
          }),
          200,
          headers: <String, String>{'Content-Type': jsonMime},
        );
      }
      if (path.endsWith('/v1/auth/verify')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'access_token': 'tok-owner-1',
            'token_type': 'bearer',
            'expires_in_seconds': 86400,
          }),
          200,
          headers: <String, String>{'Content-Type': jsonMime},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'user_id': 'user-1',
          'device_id': 'PH-1',
          'role': 'owner_phone',
          'fingerprint': 'FP',
        }),
        status,
        headers: <String, String>{'Content-Type': jsonMime},
      );
    }),
  );
}

void main() {
  group('establish owner', () {
    test(
      'contract: unlock then key then bootstrap then login, in that order',
      () async {
        final _Keys keys = _Keys();
        final _Gate gate = _Gate(LocalAuthResult.unlocked);
        final CalcarApiClient api = _api(status: 201);
        final bool ok = await establishOwner(
          displayName: 'Owner',
          keys: keys,
          gate: gate,
          api: api,
          requestId: 'req-1',
        );
        expect(ok, isTrue);
        expect(gate.calls, 1);
        expect(keys.calls, <String>['generate']);
        expect(await keys.hasKey(), isTrue);
        expect(api.token, 'tok-owner-1');
      },
    );

    test(
      'contract: refused auth generates no key and calls nothing',
      () async {
        final _Keys keys = _Keys();
        final bool ok = await establishOwner(
          displayName: 'Owner',
          keys: keys,
          gate: _Gate(LocalAuthResult.cancelled),
          api: _api(status: 201),
          requestId: 'req-1',
        );
        expect(ok, isFalse);
        expect(keys.calls, isEmpty);
        expect(await keys.hasKey(), isFalse);
      },
    );

    test(
      'contract: failed bootstrap deletes the key and reports false',
      () async {
        final _Keys keys = _Keys();
        final bool ok = await establishOwner(
          displayName: 'Owner',
          keys: keys,
          gate: _Gate(LocalAuthResult.unlocked),
          api: _api(status: 400),
          requestId: 'req-1',
        );
        expect(ok, isFalse);
        expect(keys.calls, <String>['generate', 'delete']);
        expect(await keys.hasKey(), isFalse);
      },
    );

    test(
      'contract: blank display name touches no seam',
      () async {
        final _Keys keys = _Keys();
        final _Gate gate = _Gate(LocalAuthResult.unlocked);
        final bool ok = await establishOwner(
          displayName: '   ',
          keys: keys,
          gate: gate,
          api: _api(status: 201),
          requestId: 'req-1',
        );
        expect(ok, isFalse);
        expect(gate.calls, 0);
        expect(keys.calls, isEmpty);
      },
    );

    test(
      'contract: keystore failure reports false with no network shape',
      () async {
        final _Keys keys = _Keys()..failGenerate = true;
        final bool ok = await establishOwner(
          displayName: 'Owner',
          keys: keys,
          gate: _Gate(LocalAuthResult.unlocked),
          api: _api(status: 201),
          requestId: 'req-1',
        );
        expect(ok, isFalse);
      },
    );
  });
}
