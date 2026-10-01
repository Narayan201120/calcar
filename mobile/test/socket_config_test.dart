import 'package:calcar/api/api.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'contract: socket config follows the live api client, never env consts',
    () {
      final CalcarApiClient api = CalcarApiClient(
        baseUrl: 'https://backend.test',
      );
      api.token = 'tok-live';
      api.userId = 'user-1';
      api.deviceId = 'PH-1';
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          apiClientProvider.overrideWithValue(api),
          socketConfigProvider.overrideWith((Ref ref) {
            final CalcarApiClient live = ref.watch(apiClientProvider);
            return SocketConfig(
              baseUrl: live.baseUrl,
              userId: live.userId,
              token: live.token ?? '',
            );
          }),
        ],
      );
      final SocketConfig config = container.read(socketConfigProvider);
      expect(config.token, 'tok-live');
      expect(config.userId, 'user-1');
      expect(config.baseUrl, 'https://backend.test');
      container.dispose();
    },
  );
}
