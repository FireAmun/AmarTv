import 'dart:math';

import 'package:amartv/core/backoff.dart';
import 'package:amartv/core/url_mask.dart';
import 'package:amartv/features/player/numeric_entry.dart';
import 'package:amartv/features/playlist/channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backoff', () {
    test('base delays are 1, 2, 4, 8, 16, then capped at 30 s', () {
      final b = Backoff();
      expect(
        [for (var i = 0; i < 8; i++) b.baseDelay(i).inSeconds],
        [1, 2, 4, 8, 16, 30, 30, 30],
      );
    });

    test('jitter stays within +/-20% and never exceeds the cap', () {
      final b = Backoff(random: Random(42));
      for (var i = 0; i < 50; i++) {
        final base = b.baseDelay(b.attempt).inMilliseconds;
        final d = b.next().inMilliseconds;
        expect(d, greaterThanOrEqualTo((base * 0.8).floor()));
        expect(d, lessThanOrEqualTo(min((base * 1.2).ceil(), 30000)));
      }
    });

    test('reset starts over', () {
      final b = Backoff(random: Random(1));
      b.next();
      b.next();
      b.next();
      expect(b.attempt, 3);
      b.reset();
      expect(b.attempt, 0);
      expect(b.next().inMilliseconds, lessThanOrEqualTo(1200));
    });
  });

  group('NumericEntry', () {
    test('commits the number 1.5 s after the last digit', () {
      fakeAsync((async) {
        final got = <int>[];
        final e = NumericEntry(onCommit: got.add);
        e.addDigit(1);
        async.elapse(const Duration(milliseconds: 1000));
        e.addDigit(0);
        async.elapse(const Duration(milliseconds: 1000));
        e.addDigit(5);
        expect(e.buffer, '105');
        async.elapse(const Duration(milliseconds: 1400));
        expect(got, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(got, [105]);
        expect(e.active, isFalse);
      });
    });

    test('leading zeros and zero', () {
      final got = <int>[];
      final e = NumericEntry(onCommit: got.add);
      e
        ..addDigit(0)
        ..addDigit(0)
        ..addDigit(7);
      expect(e.commit(), 7);
      e.addDigit(0);
      e.commit(); // 0 is not a channel
      expect(got, [7]);
    });

    test('too many digits restarts the buffer', () {
      final e = NumericEntry(onCommit: (_) {});
      for (final d in [1, 2, 3, 4, 5, 6]) {
        e.addDigit(d);
      }
      expect(e.buffer, '6');
      e.dispose();
    });

    test('channelByNumber resolves and handles nonexistent numbers', () {
      const list = [
        Channel(id: 'a', name: 'A', url: 'http://h/a', number: 1),
        Channel(id: 'b', name: 'B', url: 'http://h/b', number: 105),
      ];
      expect(channelByNumber(list, 105)?.id, 'b');
      expect(channelByNumber(list, 999), isNull);
    });
  });

  group('URL masking', () {
    tearDown(UrlMasker.clearSecrets);

    test('masks query credentials', () {
      expect(
        maskUrl('http://example.com/get.php?username=USER123&password=PASS456&type=m3u'),
        'http://example.com/get.php?username=***&password=***&type=m3u',
      );
    });

    test('masks xtream path credentials', () {
      expect(maskUrl('http://h.tv:8080/live/USER123/PASS456/1234.ts'), 'http://h.tv:8080/live/***/***/1234.ts');
      expect(maskUrl('http://h.tv:80/USER123/PASS456/1234'), 'http://h.tv:80/***/***/1234');
    });

    test('masks user info', () {
      expect(maskUrl('http://bob:secret@h/x'), 'http://***:***@h/x');
    });

    test('masks credentials inside error text', () {
      final msg = maskUrl('Failed to open http://h/get.php?password=abc123 (HTTP error 403)');
      expect(msg, isNot(contains('abc123')));
      expect(msg, contains('HTTP error 403'));
    });

    test('masks registered secrets anywhere', () {
      UrlMasker.addSecretsFromUrl('http://h/get.php?username=6272026&password=9988776&type=m3u');
      expect(maskUrl('login 6272026 failed with 9988776'), 'login *** failed with ***');
    });

    test('leaves normal text alone', () {
      expect(maskUrl('Buffering 50%'), 'Buffering 50%');
    });
  });
}
