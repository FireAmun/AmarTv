import 'dart:math';

/// Exponential reconnect backoff: 1, 2, 4, 8, 16, then capped at 30 s,
/// each with +/-20% jitter so several clients don't retry in lockstep.
class Backoff {
  Backoff({Random? random, this.maxDelay = const Duration(seconds: 30)})
      : _random = random ?? Random();

  final Random _random;
  final Duration maxDelay;
  int _attempt = 0;

  int get attempt => _attempt;

  /// Delay before the next attempt, without jitter.
  Duration baseDelay(int attempt) {
    final seconds = attempt >= 5 ? maxDelay.inSeconds : 1 << attempt;
    return Duration(seconds: min(seconds, maxDelay.inSeconds));
  }

  /// Returns the delay for the next attempt and advances the counter.
  Duration next() {
    final base = baseDelay(_attempt);
    _attempt++;
    final factor = 0.8 + _random.nextDouble() * 0.4; // 0.8 .. 1.2
    final ms = (base.inMilliseconds * factor).round();
    return Duration(milliseconds: min(ms, maxDelay.inMilliseconds));
  }

  void reset() => _attempt = 0;
}
