/// Prevent installation while queued repository writes or synchronization are active.
class UpdateActivity {
  static int _pending = 0;
  static bool installing = false;
  static bool get busy => _pending > 0;

  static void begin() {
    if (installing) throw StateError('应用正在更新，请稍后再操作。');
    _pending++;
  }

  static void end() {
    if (_pending > 0) _pending--;
  }
}
