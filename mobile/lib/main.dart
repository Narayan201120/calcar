// Composition root. One place builds the clients, the providers, the push
// service, and the shell, so nothing else has to know how they fit.
//
// Two inputs come from the host, not from the app: the backend base URL
// and the agent base URL, the computer over the private mesh. Both are
// compiled in with --dart-define for now. OPEN ITEM: the Owner
// establish step needs a hardware-backed key, which lives in a platform
// keystore plugin that does not exist yet, so `ownerEstablished` is a
// compile-time flag and the first-run screen is the honest default.
library;

import 'package:calcar/api/api.dart';
import 'package:calcar/app.dart';
import 'package:calcar/push/push_service.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String _backendBaseUrl = String.fromEnvironment(
  'CALCAR_BACKEND_URL',
  defaultValue: 'http://127.0.0.1:8080',
);
const String _agentBaseUrl = String.fromEnvironment(
  'CALCAR_AGENT_URL',
  defaultValue: 'http://127.0.0.1:8081',
);
const String _sessionToken = String.fromEnvironment(
  'CALCAR_TOKEN',
  defaultValue: '',
);
const String _deviceId = String.fromEnvironment(
  'CALCAR_DEVICE_ID',
  defaultValue: '',
);
const String _userId = String.fromEnvironment(
  'CALCAR_USER_ID',
  defaultValue: '',
);
const bool _ownerEstablished = bool.fromEnvironment(
  'CALCAR_OWNER_ESTABLISHED',
  defaultValue: false,
);

void main() {
  final CalcarApiClient api = CalcarApiClient(
    baseUrl: _backendBaseUrl,
    token: _sessionToken.isEmpty ? null : _sessionToken,
  );
  final AgentChannelClient agent = AgentChannelClient(
    baseUrl: _agentBaseUrl,
    token: _sessionToken,
  );
  final SnapshotSource source = HttpSnapshotSource(api: api, agent: agent);
  final DeepLinkBus bus = DeepLinkBus();

  // Push registers after the shell is up. Token sources arrive with the
  // push plugins; without them register is a no-op and nothing is sent.
  final PushService push = PushService(
    api: api,
    source: source,
    bus: bus,
    deviceId: _deviceId,
  );
  push.register();

  runApp(
    ProviderScope(
      overrides: <Override>[
        snapshotSourceProvider.overrideWithValue(source),
        apiClientProvider.overrideWithValue(api),
        agentChannelProvider.overrideWithValue(agent),
        socketConfigProvider.overrideWithValue(
          SocketConfig(
            baseUrl: _backendBaseUrl,
            userId: _userId,
            token: _sessionToken,
          ),
        ),
      ],
      child: CalcarApp(
        deps: CalcarShellDeps(
          api: api,
          // Fails closed. A real biometric gate is a platform-channel
          // implementation; until it lands, every fresh-auth call is
          // refused rather than silently allowed.
          authGate: const _UnavailableGate(),
          onEstablishOwner: (String displayName) async => false,
        ),
        start: _ownerEstablished ? CalcarStart.computers : CalcarStart.firstRun,
        deepLinkBus: bus,
      ),
    ),
  );
}

/// The stand-in biometric gate. `unavailable` is a distinct answer from
/// `cancelled`: callers treat it as a hard refusal.
class _UnavailableGate implements LocalAuthGate {
  const _UnavailableGate();

  @override
  Future<LocalAuthResult> authenticate({required String reason}) async {
    return LocalAuthResult.unavailable;
  }
}
