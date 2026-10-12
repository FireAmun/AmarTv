import 'dart:convert';

import 'package:amartv/features/playlist/channel.dart';
import 'package:amartv/features/playlist/m3u_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseM3u', () {
    test('parses standard attributes', () {
      const text = '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" tvg-logo="http://l/bbc.png" group-title="UK" tvg-chno="101",BBC One HD\n'
          'http://host/live/u/p/1.ts\n';
      final r = parseM3u(text);
      expect(r.skipped, 0);
      final c = r.channels.single;
      expect(c.name, 'BBC One HD');
      expect(c.tvgId, 'bbc1.uk');
      expect(c.logo, 'http://l/bbc.png');
      expect(c.group, 'UK');
      expect(c.tvgChno, 101);
      expect(c.number, 101);
      expect(c.url, 'http://host/live/u/p/1.ts');
    });

    test('attributes in any order, commas in name and in quoted values', () {
      const text = '#EXTM3U\n'
          '#EXTINF:-1 group-title="News, World" tvg-logo="" tvg-id="x",CNN, International, HD\n'
          'http://h/2.ts\n';
      final c = parseM3u(text).channels.single;
      expect(c.name, 'CNN, International, HD');
      expect(c.group, 'News, World');
      expect(c.tvgId, 'x');
    });

    test('handles CRLF, BOM and missing header', () {
      const text = '﻿#EXTINF:-1,One\r\nhttp://h/1\r\n#EXTINF:-1,Two\r\nhttp://h/2\r\n';
      final r = parseM3u(text);
      expect(r.channels.map((c) => c.name), ['One', 'Two']);
    });

    test('decodePlaylist strips BOM and tolerates invalid UTF-8', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('#EXTINF:-1,Café\nhttp://h/1\n'), 0xFF];
      final text = decodePlaylist(bytes);
      expect(text.startsWith('#EXTINF'), isTrue);
      expect(parseM3u(text).channels.single.name, 'Café');
    });

    test('skips malformed entries without failing the playlist', () {
      const text = '#EXTM3U\n'
          'http://orphan/url\n' // url without EXTINF
          '#EXTINF:-1,No url, followed by another extinf\n'
          '#EXTINF:-1 tvg-id="ok",Good\n'
          'http://h/good\n'
          '#EXTINF:-1,Bad url\n'
          'not a url\n'
          '#EXTINF:-1 group-title="G",\n' // empty name, no tvg-name
          'http://h/noname\n'
          '#EXTINF:garbage without comma\n'
          'http://h/x\n'
          '#EXTINF:-1,Trailing without url\n';
      final r = parseM3u(text);
      expect(r.channels.map((c) => c.name), ['Good']);
      expect(r.skipped, 6);
    });

    test('falls back to tvg-name and #EXTGRP', () {
      const text = '#EXTINF:-1 tvg-name="Named",\n#EXTGRP:Sports\nhttp://h/1\n';
      final c = parseM3u(text).channels.single;
      expect(c.name, 'Named');
      expect(c.group, 'Sports');
    });

    test('skips other directives like #EXTVLCOPT', () {
      const text = '#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=X\nhttp://h/a\n';
      expect(parseM3u(text).channels.single.url, 'http://h/a');
    });

    test('excludes VOD (movie/series) urls by default', () {
      const text = '#EXTINF:-1,Live\nhttp://h/live/u/p/1.ts\n'
          '#EXTINF:-1,Film\nhttp://h/movie/u/p/2.mp4\n'
          '#EXTINF:-1,Show\nhttp://h/series/u/p/3.mkv\n';
      expect(parseM3u(text).channels.map((c) => c.name), ['Live']);
      expect(parseM3u(text, excludeVod: false).channels.length, 3);
    });

    test('drops exact duplicates', () {
      const text = '#EXTINF:-1,A\nhttp://h/a\n#EXTINF:-1,A\nhttp://h/a\n';
      final r = parseM3u(text);
      expect(r.channels.length, 1);
      expect(r.skipped, 1);
    });

    test('empty input gives empty result', () {
      expect(parseM3u('').channels, isEmpty);
    });
  });

  group('stable ids', () {
    test('same input gives same id across parses', () {
      const text = '#EXTINF:-1 tvg-id="a",A\nhttp://h/1\n#EXTINF:-1,B\nhttp://h/2\n';
      final ids1 = parseM3u(text).channels.map((c) => c.id).toList();
      final ids2 = parseM3u('#EXTM3U\r\n$text').channels.map((c) => c.id).toList();
      expect(ids1, ids2);
      expect(ids1.toSet().length, 2);
    });

    test('id does not depend on position, group or logo', () {
      final a = parseM3u('#EXTINF:-1 group-title="X",A\nhttp://h/1\n').channels.single;
      final b = parseM3u('#EXTINF:-1,Z\nhttp://h/9\n#EXTINF:-1 group-title="Y" tvg-logo="l",A\nhttp://h/1\n')
          .channels
          .last;
      expect(a.id, b.id);
    });

    test('id differs by tvg-id, name or url', () {
      final base = Channel.stableId(tvgId: 't', name: 'n', url: 'http://h/1');
      expect(Channel.stableId(tvgId: 't2', name: 'n', url: 'http://h/1'), isNot(base));
      expect(Channel.stableId(tvgId: 't', name: 'n2', url: 'http://h/1'), isNot(base));
      expect(Channel.stableId(tvgId: 't', name: 'n', url: 'http://h/2'), isNot(base));
    });

    test('id survives a credential change in the url', () {
      expect(
        Channel.stableId(tvgId: 't', name: 'n', url: 'http://h:80/user1/pass1/123'),
        Channel.stableId(tvgId: 't', name: 'n', url: 'http://h:80/user2/pass2/123'),
      );
    });
  });

  group('channel numbers', () {
    Channel ch(String name, int? chno, int order) =>
        Channel(id: name, name: name, url: 'http://h/$name', tvgChno: chno, order: order);

    test('without tvg-chno numbers follow playlist order', () {
      final r = assignChannelNumbers([ch('a', null, 0), ch('b', null, 1), ch('c', null, 2)]);
      expect(r.map((c) => c.number), [1, 2, 3]);
    });

    test('duplicates and missing get next free numbers in playlist order', () {
      final r = assignChannelNumbers([
        ch('a', 5, 0),
        ch('b', null, 1),
        ch('c', 5, 2), // duplicate of a
        ch('d', 2, 3),
      ]);
      expect(r.map((c) => c.number), [5, 6, 7, 2]);
    });

    test('is deterministic', () {
      final input = [ch('a', 3, 0), ch('b', 3, 1), ch('c', null, 2)];
      expect(
        assignChannelNumbers(input).map((c) => c.number),
        assignChannelNumbers(input).map((c) => c.number),
      );
    });
  });
}
