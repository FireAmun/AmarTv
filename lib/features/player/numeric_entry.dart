import 'dart:async';

import '../playlist/channel.dart';

/// Collects typed digits (e.g. "1","0","5") and commits them as a channel
/// number [delay] after the last digit.
class NumericEntry {
  NumericEntry({required this.onCommit, this.delay = const Duration(milliseconds: 1500)});

  static const maxDigits = 5;

  final void Function(int number) onCommit;
  final Duration delay;

  String _buffer = '';
  Timer? _timer;

  String get buffer => _buffer;
  bool get active => _buffer.isNotEmpty;

  void addDigit(int digit) {
    assert(digit >= 0 && digit <= 9);
    if (_buffer.length >= maxDigits) _buffer = '';
    _buffer += '$digit';
    _timer?.cancel();
    _timer = Timer(delay, commit);
  }

  /// Commits immediately (also used by Enter). Returns the number, if any.
  int? commit() {
    _timer?.cancel();
    final n = int.tryParse(_buffer);
    _buffer = '';
    if (n != null && n > 0) onCommit(n);
    return n;
  }

  void cancel() {
    _timer?.cancel();
    _buffer = '';
  }

  void dispose() => _timer?.cancel();
}

/// Finds the channel with resolved [number], or null if it doesn't exist.
Channel? channelByNumber(Iterable<Channel> channels, int number) {
  for (final c in channels) {
    if (c.number == number) return c;
  }
  return null;
}
