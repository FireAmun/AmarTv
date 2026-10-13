import '../settings/app_settings.dart';

final _xtreamLive = RegExp(r'^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/(\d+)(?:\.(?:ts|m3u8))?$', caseSensitive: false);

/// The url to open for a live channel in the chosen [format]. Xtream panels
/// serve every live stream as `.../live/USER/PASS/ID.ts` and `.m3u8`; other
/// urls are returned unchanged.
String liveStreamUrl(String url, LiveFormat format) {
  final m = _xtreamLive.firstMatch(url.trim());
  if (m == null || url.contains('/movie/') || url.contains('/series/')) return url;
  final ext = format == LiveFormat.hls ? 'm3u8' : 'ts';
  return '${m[1]}/live/${m[2]}/${m[3]}/${m[4]}.$ext';
}
