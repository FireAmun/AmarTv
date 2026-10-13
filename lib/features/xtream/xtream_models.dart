import 'dart:convert';

/// Pure parsing of Xtream `player_api.php` responses. Panels differ a lot, so
/// every field is optional and bad items are skipped.

class AccountInfo {
  const AccountInfo({
    required this.status,
    this.expires,
    this.activeConnections,
    this.maxConnections,
    this.isTrial = false,
  });

  final String status;

  /// null = no expiry ("unlimited").
  final DateTime? expires;
  final int? activeConnections;
  final int? maxConnections;
  final bool isTrial;

  bool get isActive => status.toLowerCase() == 'active';

  Duration? get remaining => expires?.difference(DateTime.now());

  static AccountInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final u = json['user_info'];
    if (u is! Map) return null;
    return AccountInfo(
      status: '${u['status'] ?? 'Unknown'}',
      expires: _epoch(u['exp_date']),
      activeConnections: _int(u['active_cons']),
      maxConnections: _int(u['max_connections']),
      isTrial: '${u['is_trial']}' == '1',
    );
  }
}

class EpgProgram {
  const EpgProgram({required this.title, required this.start, required this.end, this.description = ''});

  final String title;
  final DateTime start;
  final DateTime end;
  final String description;

  bool isOnAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  double progressAt(DateTime t) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0, 1).toDouble();
  }
}

class NowNext {
  const NowNext(this.now, this.next);
  final EpgProgram? now;
  final EpgProgram? next;

  bool get isEmpty => now == null && next == null;
}

/// `get_short_epg` -> programs sorted by start time.
List<EpgProgram> parseShortEpg(Object? json) {
  final list = json is Map ? json['epg_listings'] : json;
  if (list is! List) return const [];
  final out = <EpgProgram>[];
  for (final e in list) {
    if (e is! Map) continue;
    final start = _epoch(e['start_timestamp']) ?? _dateTime(e['start']);
    final end = _epoch(e['stop_timestamp'] ?? e['end_timestamp']) ?? _dateTime(e['end'] ?? e['stop']);
    final title = decodeMaybeBase64('${e['title'] ?? ''}').trim();
    if (start == null || end == null || title.isEmpty || !end.isAfter(start)) continue;
    out.add(EpgProgram(
      title: title,
      start: start,
      end: end,
      description: decodeMaybeBase64('${e['description'] ?? ''}').trim(),
    ));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

NowNext nowNextAt(List<EpgProgram> programs, DateTime t) {
  EpgProgram? now;
  EpgProgram? next;
  for (final p in programs) {
    if (p.isOnAt(t)) {
      now = p;
    } else if (p.start.isAfter(t)) {
      next ??= p;
    }
  }
  return NowNext(now, next);
}

class SeriesCategory {
  const SeriesCategory(this.id, this.name);
  final String id;
  final String name;
}

class SeriesItem {
  const SeriesItem({required this.id, required this.name, this.cover = '', this.categoryId = '', this.plot = '', this.year = ''});
  final int id;
  final String name;
  final String cover;
  final String categoryId;
  final String plot;
  final String year;
}

class MovieItem {
  const MovieItem({
    required this.id,
    required this.name,
    required this.extension,
    this.cover = '',
    this.categoryId = '',
    this.rating = '',
    this.year = '',
  });
  final int id;
  final String name;
  final String extension;
  final String cover;
  final String categoryId;
  final String rating;
  final String year;
}

class Episode {
  const Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.extension,
    this.plot = '',
    this.duration,
    this.image = '',
  });
  final String id;
  final int season;
  final int number;
  final String title;
  final String extension;
  final String plot;
  final Duration? duration;
  final String image;
}

List<SeriesCategory> parseCategories(Object? json) => [
      for (final c in _items(json))
        if (c is Map && c['category_id'] != null)
          SeriesCategory('${c['category_id']}', '${c['category_name'] ?? ''}'.trim()),
    ];

List<SeriesItem> parseSeriesList(Object? json) {
  final out = <SeriesItem>[];
  for (final s in _items(json)) {
    if (s is! Map) continue;
    final id = _int(s['series_id']);
    final name = '${s['name'] ?? ''}'.trim();
    if (id == null || name.isEmpty) continue;
    out.add(SeriesItem(
      id: id,
      name: name,
      cover: '${s['cover'] ?? ''}'.trim(),
      categoryId: '${s['category_id'] ?? ''}',
      plot: '${s['plot'] ?? ''}'.trim(),
      year: '${s['releaseDate'] ?? s['release_date'] ?? s['year'] ?? ''}'.trim(),
    ));
  }
  return out;
}

/// `get_vod_streams` -> movies. The year comes from a "(2024)" name suffix
/// when the panel has no year field.
List<MovieItem> parseMovies(Object? json) {
  final out = <MovieItem>[];
  for (final m in _items(json)) {
    if (m is! Map) continue;
    final id = _int(m['stream_id']);
    final name = '${m['name'] ?? ''}'.trim();
    if (id == null || name.isEmpty) continue;
    final ext = '${m['container_extension'] ?? ''}'.trim();
    final rating = '${m['rating'] ?? ''}'.trim();
    out.add(MovieItem(
      id: id,
      name: name,
      extension: ext.isEmpty || ext == 'null' ? 'mp4' : ext,
      cover: '${m['stream_icon'] ?? ''}'.trim(),
      categoryId: '${m['category_id'] ?? ''}',
      rating: rating == '0' || rating == 'null' ? '' : rating,
      year: RegExp(r'\((\d{4})\)\s*$').firstMatch(name)?.group(1) ?? '${m['year'] ?? ''}'.trim(),
    ));
  }
  return out;
}

/// `get_series_info` -> episodes sorted by season and number. The
/// `episodes` field is a map keyed by season ("1": [...]) or a plain list.
List<Episode> parseSeriesEpisodes(Object? json) {
  if (json is! Map) return const [];
  final raw = json['episodes'];
  final groups = <Object?>[
    if (raw is Map) ...raw.values,
    // A list of per-season lists, or one flat list of episodes.
    if (raw is List) ...raw.whereType<List>(),
    if (raw is List && raw.any((e) => e is Map)) raw,
  ];
  final out = <Episode>[];
  for (final group in groups) {
    if (group is! List) continue;
    for (final e in group) {
      if (e is! Map || e['id'] == null) continue;
      final info = e['info'] is Map ? e['info'] as Map : const {};
      final secs = _int(info['duration_secs']);
      out.add(Episode(
        id: '${e['id']}',
        season: _int(e['season']) ?? 1,
        number: _int(e['episode_num']) ?? 0,
        title: '${e['title'] ?? ''}'.trim(),
        extension: '${e['container_extension'] ?? 'mp4'}'.trim(),
        plot: '${info['plot'] ?? ''}'.trim(),
        duration: secs == null || secs <= 0 ? null : Duration(seconds: secs),
        image: '${info['movie_image'] ?? ''}'.trim(),
      ));
    }
  }
  out.sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.number.compareTo(b.number));
  return out;
}

/// Xtream stream id from a live url: `.../live/U/P/123.ts` or `.../U/P/123`.
int? streamIdFromUrl(String url) {
  final m = RegExp(r'/(\d+)(?:\.[A-Za-z0-9]{1,5})?(?:\?.*)?$').firstMatch(url.trim());
  return m == null ? null : int.tryParse(m[1]!);
}

/// Xtream panels base64-encode EPG titles; some don't.
String decodeMaybeBase64(String s) {
  final t = s.trim();
  if (t.isEmpty || t.length % 4 != 0 || !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(t)) return s;
  try {
    return utf8.decode(base64.decode(t));
  } catch (_) {
    return s;
  }
}

List<dynamic> _items(Object? json) {
  if (json is List) return json;
  if (json is Map) return json.values.toList();
  return const [];
}

int? _int(Object? v) => v == null ? null : int.tryParse('$v'.trim());

DateTime? _epoch(Object? v) {
  final n = _int(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

DateTime? _dateTime(Object? v) => v == null ? null : DateTime.tryParse('$v'.trim());
