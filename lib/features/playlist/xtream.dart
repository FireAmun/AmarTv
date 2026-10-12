import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'm3u_parser.dart';

/// Fallback for "Xtream Codes" panels: many providers disable or filter the
/// `get.php` M3U endpoint, while their apps log in through `player_api.php`
/// with the same username/password.
class XtreamLogin {
  const XtreamLogin({required this.base, required this.username, required this.password});

  /// e.g. `http://host:8080` (scheme, host and port only).
  final String base;
  final String username;
  final String password;

  /// Extracts login data from a `.../get.php?username=U&password=P...` url.
  static XtreamLogin? fromPlaylistUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final user = uri.queryParameters['username'];
    final pass = uri.queryParameters['password'];
    if (user == null || pass == null || user.isEmpty || pass.isEmpty) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return XtreamLogin(base: '${uri.scheme}://${uri.host}$port', username: user, password: pass);
  }

  Uri api(String? action) => Uri.parse('$base/player_api.php').replace(queryParameters: {
        'username': username,
        'password': password,
        if (action != null) 'action': action,
      });

  String liveUrl(Object streamId) => '$base/live/$username/$password/$streamId.ts';

  String movieUrl(Object streamId, String ext) =>
      '$base/movie/$username/$password/$streamId.${ext.isEmpty ? 'mp4' : ext}';
}

class XtreamPayload {
  const XtreamPayload({
    required this.login,
    required this.liveCategories,
    required this.liveStreams,
    this.vodCategories,
    this.vodStreams,
  });

  final XtreamLogin login;
  final String liveCategories;
  final String liveStreams;
  final String? vodCategories;
  final String? vodStreams;
}

Future<ParseResult> parseXtreamInIsolate(XtreamPayload payload) => compute(parseXtream, payload);

/// Builds channels from Xtream JSON responses. Bad items are skipped.
ParseResult parseXtream(XtreamPayload p) {
  final channels = <Channel>[];
  final seen = <String>{};
  var skipped = 0;

  Map<String, String> categories(String? json) {
    final out = <String, String>{};
    for (final c in _list(json)) {
      if (c is Map && c['category_id'] != null) {
        out['${c['category_id']}'] = '${c['category_name'] ?? ''}'.trim();
      }
    }
    return out;
  }

  void add(dynamic item, Map<String, String> cats, String Function(Map item) urlOf, {String prefix = ''}) {
    if (item is! Map || item['stream_id'] == null) {
      skipped++;
      return;
    }
    final name = '${item['name'] ?? ''}'.trim();
    if (name.isEmpty) {
      skipped++;
      return;
    }
    final url = urlOf(item);
    final tvgId = '${item['epg_channel_id'] ?? ''}'.trim();
    final id = Channel.stableId(tvgId: tvgId, name: name, url: url);
    if (!seen.add(id)) {
      skipped++;
      return;
    }
    final group = cats['${item['category_id']}'] ?? '';
    final num = int.tryParse('${item['num'] ?? ''}');
    channels.add(Channel(
      id: id,
      name: name,
      url: url,
      logo: '${item['stream_icon'] ?? ''}'.trim(),
      group: prefix.isEmpty ? group : '$prefix$group',
      tvgId: tvgId,
      tvgChno: prefix.isEmpty && num != null && num > 0 ? num : null,
      order: channels.length,
    ));
  }

  final liveCats = categories(p.liveCategories);
  for (final item in _list(p.liveStreams)) {
    add(item, liveCats, (i) => p.login.liveUrl(i['stream_id']));
  }
  if (p.vodStreams != null) {
    final vodCats = categories(p.vodCategories);
    for (final item in _list(p.vodStreams)) {
      add(item, vodCats, (i) => p.login.movieUrl(i['stream_id'], '${i['container_extension'] ?? ''}'),
          prefix: 'Movies: ');
    }
  }
  return ParseResult(assignChannelNumbers(channels), skipped);
}

List<dynamic> _list(String? json) {
  if (json == null || json.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is List) return decoded;
    if (decoded is Map) return decoded.values.toList(); // some panels return maps
  } catch (_) {}
  return const [];
}
