// App-level heartbeat accounting for the foreground socket.
//
// Mirrors backend/ws/hub.go: the server expects a client heartbeat
// every 30 seconds and drops connections silent for 3 windows. This
// tracker is the client mirror: any inbound message resets the miss
// count, each 30s tick with no inbound traffic counts one miss, and
// [shouldDrop] goes true after [maxMissed] consecutive misses so the
// socket client can close the socket and show the disconnected banner.
//
// Pure logic, no timers or sockets, so unit tests drive it directly.

/// Counts missed heartbeat windows. See file docs for the contract.
class HeartbeatTracker {
  /// Misses tolerated before the connection counts as dropped.
  static const int maxMissed = 3;

  /// Consecutive ticks with no inbound message.
  int missed = 0;

  bool _seenSinceTick = false;

  /// Call on every inbound message, including heartbeats.
  void markMessage() {
    missed = 0;
    _seenSinceTick = true;
  }

  /// Call once per heartbeat interval. Returns true when the
  /// connection must now be treated as dropped.
  bool tick() {
    if (_seenSinceTick) {
      _seenSinceTick = false;
      return false;
    }
    missed += 1;
    return shouldDrop;
  }

  /// True after [maxMissed] consecutive silent intervals.
  bool get shouldDrop => missed >= maxMissed;

  /// Resets misses and the seen flag, e.g. after a reconnect.
  void reset() {
    missed = 0;
    _seenSinceTick = false;
  }
}
