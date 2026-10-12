import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/url_mask.dart';

class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.url,
    this.logo = '',
    this.group = '',
    this.tvgId = '',
    this.tvgChno,
    this.number = 0,
    this.order = 0,
  });

  /// Stable across playlist refreshes: hash of tvg-id + name + url.
  /// Credentials are stripped from the url first, so favorites/history also
  /// survive a username/password change at the provider.
  final String id;
  final String name;
  final String url;
  final String logo;
  final String group;
  final String tvgId;

  /// Raw tvg-chno from the playlist (may be missing or duplicated).
  final int? tvgChno;

  /// Resolved, unique channel number (see [assignChannelNumbers]).
  final int number;

  /// Position in the playlist.
  final int order;

  Channel copyWith({int? number}) => Channel(
        id: id,
        name: name,
        url: url,
        logo: logo,
        group: group,
        tvgId: tvgId,
        tvgChno: tvgChno,
        number: number ?? this.number,
        order: order,
      );

  static String stableId({
    required String tvgId,
    required String name,
    required String url,
  }) {
    final cleanUrl = UrlMasker.maskPatterns(url.trim());
    final bytes = utf8.encode('$tvgId\u0000$name\u0000$cleanUrl');
    return sha1.convert(bytes).toString().substring(0, 20);
  }
}
