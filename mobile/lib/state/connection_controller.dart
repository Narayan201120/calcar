// Connection state: the disconnected banner flag.
//
// Starts disconnected (banner up) until the first socket connects.
// [showBanner] derives from the two stored bits and is never stored
// itself. While the banner is up the merge step freezes workflow
// controllers and refetches snapshots on reconnect; a drop never marks
// a workflow completed, it only freezes it.
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ConnectionState {
  final bool connected;
  final bool needsCatchup;

  const ConnectionState({
    required this.connected,
    required this.needsCatchup,
  });

  factory ConnectionState.initial() {
    return const ConnectionState(connected: false, needsCatchup: false);
  }

  bool get showBanner => !connected || needsCatchup;
}

class ConnectionController extends StateNotifier<ConnectionState> {
  ConnectionController() : super(ConnectionState.initial());

  void markConnected() {
    state = const ConnectionState(connected: true, needsCatchup: false);
  }

  void markDisconnected() {
    if (state.connected) {
      state = ConnectionState(
        connected: false,
        needsCatchup: state.needsCatchup,
      );
    }
  }

  void markCatchupNeeded() {
    state = ConnectionState(
      connected: state.connected,
      needsCatchup: true,
    );
  }

  void markCaughtUp() {
    state = ConnectionState(
      connected: state.connected,
      needsCatchup: false,
    );
  }
}
