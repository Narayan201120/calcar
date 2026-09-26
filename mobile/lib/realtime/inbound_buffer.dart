// Bounded inbound buffer for foreground socket events.
//
// Contract: the phone holds at most [capacity] unprocessed events
// (default 64, matching backend SendBufferSize in backend/ws/hub.go).
// When full, new events are dropped, [dropped] counts them, and
// [needsCatchup] latches true so the UI shows the disconnected banner
// and refetches a snapshot over authenticated HTTP. Clearing the flag
// is an explicit caller act after that refetch completes.

/// Fixed-capacity FIFO that drops new items instead of growing.
class InboundBuffer<T> {
  /// Maximum held items before drops start.
  final int capacity;

  final List<T> _items = <T>[];

  /// Total dropped items since creation or last [reset].
  int dropped = 0;

  /// Latched on the first drop. Cleared only by [markCaughtUp].
  bool needsCatchup = false;

  InboundBuffer({this.capacity = 64}) : assert(capacity > 0);

  /// Current held items, oldest first.
  List<T> get items => List<T>.unmodifiable(_items);

  int get length => _items.length;

  bool get isFull => _items.length >= capacity;

  /// Adds [item]. Returns false and records a drop when full.
  bool add(T item) {
    if (_items.length >= capacity) {
      dropped += 1;
      needsCatchup = true;
      return false;
    }
    _items.add(item);
    return true;
  }

  /// Removes and returns all held items, oldest first.
  List<T> drain() {
    if (_items.isEmpty) {
      return <T>[];
    }
    final List<T> out = List<T>.from(_items);
    _items.clear();
    return out;
  }

  /// Call after the snapshot refetch that repairs a drop gap.
  void markCaughtUp() {
    needsCatchup = false;
  }

  /// Clears items, drop count, and the catch-up flag.
  void reset() {
    _items.clear();
    dropped = 0;
    needsCatchup = false;
  }
}
