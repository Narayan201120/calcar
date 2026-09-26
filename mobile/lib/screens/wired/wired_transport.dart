// Transport seams for the wired screens.
//
// The state layer owns snapshots and deltas and never knows how bytes
// travel. These two providers are the only place a wired screen reaches
// for a client, and the app entry point overrides both with the
// authenticated instances: the control-plane client for pairing, device,
// and trust calls, the agent channel for workflow data.
//
// Nothing here fires a request on its own. A wired screen reads the
// client inside a callback or a provider body, so an unwired screen
// costs no socket and no token, and a missing override fails loudly at
// the call site instead of silently sending nothing.
import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/api/client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Control-plane client. Throws until the app overrides it.
final apiClientProvider = Provider<CalcarApiClient>((Ref ref) {
  throw UnimplementedError(
    'app entry point: override apiClientProvider with the authed client',
  );
});

/// Authenticated channel to the managed computers. Throws until the app
/// overrides it. Sysinfo, workflow inputs, and approval resolves all
/// ride this channel, never the control plane, because the backend
/// brokers identity and presence only.
final agentChannelProvider = Provider<AgentChannelClient>((Ref ref) {
  throw UnimplementedError(
    'app entry point: override agentChannelProvider with the authed channel',
  );
});
