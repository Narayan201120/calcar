// Token rotation: a mounted socket binding redials with the new creds
// exactly once. Fakes only: the channel factory counts dials and throws,
// so nothing here touches the network and failures reuse the client
// backoff path.
import 'package:calcar/realtime/realtime.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dial counter plus the URIs dialed, so tests assert the new token rode
/// the redial query string.
class DialLog {
  int dials = 0;
  final List<String> uris = <String>[];
}

SocketChannelFactory countingFactory(DialLog log) {
  return (Uri uri, Iterable<String>? protocols) {
    log.dials += 1;
    log.uris.add(uri.toString());
    throw StateError('no sockets in unit tests');
  };
}

CalcarSocketClient _client(SocketConfig config, DialLog log) {
  return CalcarSocketClient(
    baseUrl: config.baseUrl,
    userId: config.userId,
    token: config.token,
    channelFactory: countingFactory(log),
  );
}

RealtimeBinding _binding(String token, DialLog log) {
  final SocketConfig config = SocketConfig(
    baseUrl: 'wss://example.invalid',
    userId: 'u1',
    token: token,
  );
  return RealtimeBinding(
    socket: _client(config, log),
    config: config,
    socketFactory: (SocketConfig next) => _client(next, log),
  );
}

void main() {
  group('token rotation on a mounted binding', () {
    test(
      'contract: token rotation redials once with the new token',
      () async {
        final DialLog log = DialLog();
        final RealtimeBinding binding = _binding('tok-old', log);
        addTearDown(binding.dispose);
        binding.mount();
        expect(log.dials, 1);
        expect(log.uris.single, contains('tok-old'));

        await binding.updateToken('tok-new');

        expect(binding.currentToken, 'tok-new');
        expect(log.dials, 2);
        expect(log.uris[1], contains('tok-new'));

        // Same token again is a no-op, never a second dial.
        await binding.updateToken('tok-new');
        expect(log.dials, 2);
      },
    );

    test(
      'contract: concurrent token rotations share one flight',
      () async {
        final DialLog log = DialLog();
        final RealtimeBinding binding = _binding('tok-old', log);
        addTearDown(binding.dispose);
        binding.mount();

        final Future<void> first = binding.updateToken('tok-new');
        final Future<void> second = binding.updateToken('tok-new');
        expect(identical(first, second), isTrue);
        await first;
        await second;

        expect(binding.currentToken, 'tok-new');
        expect(log.dials, 2);
      },
    );

    test(
      'contract: token rotation while disposed never dials',
      () async {
        final DialLog log = DialLog();
        final RealtimeBinding binding = _binding('tok-old', log);
        binding.mount();
        expect(log.dials, 1);
        binding.dispose();

        await binding.updateToken('tok-new');

        expect(log.dials, 1);
        expect(binding.currentToken, 'tok-old');
      },
    );

    test(
      'contract: token rotation before mount stores without dialing',
      () async {
        final DialLog log = DialLog();
        final RealtimeBinding binding = _binding('tok-old', log);
        addTearDown(binding.dispose);

        await binding.updateToken('tok-new');

        expect(log.dials, 0);
        expect(binding.currentToken, 'tok-new');
        binding.mount();
        expect(log.dials, 1);
        expect(log.uris.single, contains('tok-new'));
      },
    );
  });

  group('token rotation through providers', () {
    test(
      'contract: socket config token change reconnects the mounted '
      'binding exactly once',
      () async {
        final DialLog log = DialLog();
        final StateProvider<String> tokenState = StateProvider<String>(
          (Ref ref) => 'tok-old',
        );
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            socketChannelFactoryProvider.overrideWithValue(
              countingFactory(log),
            ),
            socketConfigProvider.overrideWith((Ref ref) {
              return SocketConfig(
                baseUrl: 'wss://example.invalid',
                userId: 'u1',
                token: ref.watch(tokenState),
              );
            }),
          ],
        );
        addTearDown(container.dispose);
        final ProviderSubscription<RealtimeBinding> sub =
            container.listen<RealtimeBinding>(
              realtimeBindingProvider,
              (RealtimeBinding? previous, RealtimeBinding next) {},
            );
        addTearDown(sub.close);

        final RealtimeBinding binding = container.read(
          realtimeBindingProvider,
        );
        expect(log.dials, 1);
        expect(log.uris.single, contains('tok-old'));

        container.read(tokenState.notifier).state = 'tok-new';
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Same mounted binding, redialed once with the new token.
        expect(log.dials, 2);
        expect(log.uris[1], contains('tok-new'));
        expect(
          identical(binding, container.read(realtimeBindingProvider)),
          isTrue,
        );
        expect(
          container.read(realtimeBindingProvider).currentToken,
          'tok-new',
        );

        // Setting the same token again emits nothing and dials nothing.
        container.read(tokenState.notifier).state = 'tok-new';
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(log.dials, 2);
      },
    );
  });
}
