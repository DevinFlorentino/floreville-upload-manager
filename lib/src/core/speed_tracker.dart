/// Exponentially smoothed transfer-rate estimate.
class SpeedTracker {
  SpeedTracker({
    int initialBytes = 0,
    this.smoothing = 0.3,
    this.minSampleInterval = const Duration(milliseconds: 250),
    DateTime? start,
  })  : _lastBytes = initialBytes,
        _lastTime = start ?? DateTime.now();

  /// Weight of the newest sample (0–1).
  final double smoothing;
  final Duration minSampleInterval;

  int _lastBytes;
  DateTime _lastTime;
  double _speed = 0;

  double get bytesPerSecond => _speed;

  /// Feeds the latest byte count; returns the current smoothed speed.
  double sample(int bytes, [DateTime? at]) {
    final now = at ?? DateTime.now();
    final elapsedMicros = now.difference(_lastTime).inMicroseconds;
    if (elapsedMicros < minSampleInterval.inMicroseconds) return _speed;

    final delta = bytes - _lastBytes;
    // A negative delta means the adapter restarted from an earlier offset —
    // rebase without polluting the average.
    if (delta >= 0 && elapsedMicros > 0) {
      final instant = delta / (elapsedMicros / Duration.microsecondsPerSecond);
      _speed = _speed == 0
          ? instant
          : _speed * (1 - smoothing) + instant * smoothing;
    }
    _lastBytes = bytes;
    _lastTime = now;
    return _speed;
  }

  Duration? etaFor(int remainingBytes) {
    if (_speed <= 0 || remainingBytes <= 0) return null;
    return Duration(milliseconds: (remainingBytes / _speed * 1000).round());
  }
}
