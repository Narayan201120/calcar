import 'dart:math' as math;

// Reconnect backoff for the foreground socket.
//
// Contract: backoff only runs while the owning widget is still mounted.
// The socket client checks [shouldReconnect] (or equivalently its own
// mounted flag) before every reconnect timer fires. Once [dispose] ran,
// no timer may open a new socket. Delays grow exponentially from
// [initialDelay] by [multiplier] up to [maxDelay]; a successful connect
// calls [reset] so the next failure starts fast again.
//
// Pure logic, no timers or sockets, so unit tests drive it directly.

/// Exponential backoff with a mount gate. See file docs for the contract.
class ReconnectPolicy {
  /// First retry delay.
  final Duration initialDelay;

  /// Ceiling for any retry delay.
  final Duration maxDelay;

  /// Growth factor per consecutive failure.
  final double multiplier;

  int _attempts = 0;

  ReconnectPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
  });

  /// Consecutive failures since the last [reset].
  int get attempts => _attempts;

  /// Next retry delay. Each call consumes one attempt.
  Duration nextDelay() {
    final double grown =
        initialDelay.inMilliseconds * math.pow(multiplier, _attempts);
    _attempts += 1;
    if (grown >= maxDelay.inMilliseconds) {
      return maxDelay;
    }
    return Duration(milliseconds: grown.toInt());
  }

  /// Call after a successful connect so the next failure starts fast.
  void reset() {
    _attempts = 0;
  }

  /// Reconnects are allowed only while the owner is still mounted.
  /// The socket client must call this (or check its own mounted flag)
  /// inside every reconnect timer before dialing again.
  static bool shouldReconnect({required bool mounted}) => mounted;
}
