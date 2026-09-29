// Composition root. One place builds the clients, the providers, the push
// service, and the shell, so nothing else has to know how they fit.
//
// Two inputs come from the host, not from the app: the backend base URL
// and the agent base URL, the computer over the private mesh. Both are
// compiled in with --dart-define for now. Owner establish runs through
// the biometric gate plus the hardware-wrapped key service above.
library;

import 'package:calcar/api/api.dart';
import 'package:calcar/app.dart';
import 'package:calcar/auth/biometric_gate.dart';
import 'package:calcar/auth/session_store.dart';
import 'package:calcar/keys/owner_keys.dart';
import 'package:calcar/onboarding/owner_setup.dart';
import 'package:calcar/push/push_service.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final CalcarApiClient api = CalcarApiClient(
    baseUrl: _backendBaseUrl,
    token: _sessionToken.isEmpty ? null : _sessionToken,
  );
  CalcarStart start =
      _ownerEstablished ? CalcarStart.computers : CalcarStart.firstRun;
  if (!_ownerEstablished) {
    start = await _restoreSession(api);
  }
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
          const SocketConfig(
            baseUrl: _backendBaseUrl,
            userId: _userId,
            token: _sessionToken,
          ),
        ),
      ],
      child: CalcarApp(
        deps: CalcarShellDeps(
          api: api,
          // Real gate plus real key service. Biometric refusal fails
          // closed here exactly as it does everywhere else.
          authGate: BiometricGate(),
          onEstablishOwner: (String displayName) => establishOwner(
            displayName: displayName,
            keys: OwnerKeyService(),
            gate: BiometricGate(),
            api: api,
            requestId: newRequestId(),
            session: SessionStore(),
          ),
        ),
        start: start,
        deepLinkBus: bus,
      ),
    ),
  );
}

/// Restores the persisted Owner session when one exists and still
/// validates server side. Returns the matching start: lock-first when
/// the session is live, full setup otherwise. A dead token clears
/// itself so the phone re-registers instead of failing half-open.
Future<CalcarStart> _restoreSession(CalcarApiClient api) async {
  final SessionStore sessions = SessionStore();
  final OwnerSession? saved = await sessions.load();
  if (saved == null) {
    return CalcarStart.firstRun;
  }
  api.token = saved.token;
  api.deviceId = saved.deviceId;
  api.userId = saved.userId;
  try {
    await api.listDevices();
    return CalcarStart.returning;
  } on Object catch (_) {
    api.clearToken();
    api.deviceId = '';
    api.userId = '';
    await sessions.clear();
    return CalcarStart.firstRun;
  }
}
