import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'channel.dart';

class ParseResult {
  const ParseResult(this.channels, this.skipped);
  final List<Channel> channels;

  /// Malformed or filtered entries that were dropped.
  final int skipped;
}

/// Decodes raw playlist bytes: UTF-8 with or without BOM, tolerant of bad
/// sequences.
String decodePlaylist(List<int> bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  return text;
}

/// Runs [parseM3u] in a background isolate.
Future<ParseResult> parseM3uInIsolate(String text, {bool excludeVod = true}) {
  return compute(
    (String t) => parseM3u(t, excludeVod: excludeVod),
    text,
  );
}

final _attr = RegExp(r'''([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,"']+))''');
final _vodPath = RegExp(r'/(movie|series)/', caseSensitive: false);

/// Parses an M3U/M3U8 playlist. Never throws for bad entries: they are
/// skipped and counted. Channels get stable ids and resolved numbers.
ParseResult parseM3u(String text, {bool excludeVod = true}) {
  if (text.startsWith('﻿')) text = text.substring(1);

  final channels = <Channel>[];
  final seenIds = <String>{};
  var skipped = 0;

  Map<String, String>? attrs;
  String? name;
  String? extGroup;

  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      final upper = line.length >= 8 ? line.substring(0, 8).toUpperCase() : line.toUpperCase();
      if (upper.startsWith('#EXTINF:')) {
        // A previous #EXTINF without url is malformed.
        if (attrs != null) skipped++;
        final parsed = _parseExtInf(line.substring(8));
        attrs = parsed.$1;
        name = parsed.$2;
        extGroup = null;
      } else if (upper.startsWith('#EXTGRP:')) {
        extGroup = line.substring(8).trim();
      }
      continue;
    }

    // A url line.
    if (attrs == null) {
      skipped++; // url without #EXTINF
      continue;
    }
    final url = line;
    final info = attrs;
    attrs = null;

    if (!_looksLikeUrl(url) || (excludeVod && _vodPath.hasMatch(url))) {
      skipped++;
      continue;
    }

    var displayName = (name ?? '').trim();
    if (displayName.isEmpty) displayName = (info['tvg-name'] ?? '').trim();
    if (displayName.isEmpty) {
      skipped++;
      continue;
    }

    final tvgId = (info['tvg-id'] ?? '').trim();
    final id = Channel.stableId(tvgId: tvgId, name: displayName, url: url);
    if (!seenIds.add(id)) {
      skipped++; // exact duplicate entry
      continue;
    }

    final chno = int.tryParse((info['tvg-chno'] ?? '').trim());
    channels.add(Channel(
      id: id,
      name: displayName,
      url: url,
      logo: (info['tvg-logo'] ?? '').trim(),
      group: ((info['group-title'] ?? '').trim().isNotEmpty
              ? info['group-title']!
              : (extGroup ?? ''))
          .trim(),
      tvgId: tvgId,
      tvgChno: (chno != null && chno > 0) ? chno : null,
      order: channels.length,
    ));
  }
  if (attrs != null) skipped++; // trailing #EXTINF without url

  return ParseResult(assignChannelNumbers(channels), skipped);
}

bool _looksLikeUrl(String s) {
  final i = s.indexOf('://');
  return i > 0 && i < 12 && s.length > i + 3 && !s.contains(' ');
}

/// Splits `-1 tvg-id="x" group-title="A, B",Name, with commas` into
/// attributes and display name. The separating comma is the first one
/// outside quotes.
(Map<String, String>, String) _parseExtInf(String body) {
  var quote = '';
  var split = -1;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
    } else if (c == '"' || c == "'") {
      // Only treat as a quote when it opens an attribute value (after '=').
      if (i > 0 && body[i - 1] == '=') quote = c;
    } else if (c == ',') {
      split = i;
      break;
    }
  }
  final head = split >= 0 ? body.substring(0, split) : body;
  final name = split >= 0 ? body.substring(split + 1) : '';

  final attrs = <String, String>{};
  for (final m in _attr.allMatches(head)) {
    attrs[m[1]!.toLowerCase()] = m[2] ?? m[3] ?? m[4] ?? '';
  }
  return (attrs, name);
}

/// Gives every channel a unique number, deterministically:
/// 1. channels with a valid tvg-chno keep it (first in playlist order wins
///    when duplicated);
/// 2. the rest get the next free numbers after the highest one, in playlist
///    order. Without any tvg-chno this is simply 1..n in playlist order.
List<Channel> assignChannelNumbers(List<Channel> channels) {
  final used = <int>{};
  final numbers = List<int>.filled(channels.length, 0);
  for (var i = 0; i < channels.length; i++) {
    final c = channels[i].tvgChno;
    if (c != null && c > 0 && used.add(c)) numbers[i] = c;
  }
  var next = used.isEmpty ? 1 : used.reduce((a, b) => a > b ? a : b) + 1;
  for (var i = 0; i < channels.length; i++) {
    if (numbers[i] == 0) numbers[i] = next++;
  }
  return [
    for (var i = 0; i < channels.length; i++) channels[i].copyWith(number: numbers[i]),
  ];
}
