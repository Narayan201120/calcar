import 'package:calcar/keys/owner_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('session roundtrip', () {
    test(
      'contract: save then load returns the same session',
      () async {
        final _MapStore backing = _MapStore();
        final SessionStore store = SessionStore(store: backing);
        await store.save(
          const OwnerSession(
            deviceId: 'PH-1',
            userId: 'user-1',
            token: 'tok-1',
          ),
        );
        expect(await store.load(), const OwnerSession(
          deviceId: 'PH-1',
          userId: 'user-1',
          token: 'tok-1',
        ));
      },
    );

    test(
      'contract: empty store loads nothing',
      () async {
        final SessionStore store = SessionStore(store: _MapStore());
        expect(await store.load(), isNull);
      },
    );

    test(
      'contract: partial session loads nothing and clears itself',
      () async {
        final _MapStore backing = _MapStore();
        await backing.write(SessionStore.tokenKey, 'tok-1');
        final SessionStore store = SessionStore(store: backing);
        expect(await store.load(), isNull);
        expect(await backing.read(SessionStore.tokenKey), isNull);
      },
    );

    test(
      'contract: clear forgets everything',
      () async {
        final _MapStore backing = _MapStore();
        final SessionStore store = SessionStore(store: backing);
        await store.save(
          const OwnerSession(
            deviceId: 'PH-1',
            userId: 'user-1',
            token: 'tok-1',
          ),
        );
        await store.clear();
        expect(await store.load(), isNull);
      },
    );
  });
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
