import '../playlist/channel.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';

/// The playable item for an episode. Name format "Series - S1E04  Title";
/// tvgId `series:ID` links it back to its series (resume, next episode).
Channel episodeMedia(XtreamApi api, {required int seriesId, required String seriesName, required String cover, required Episode e}) {
  final url = api.episodeUrl(e);
  final title = e.title.isEmpty ? 'Episode ${e.number}' : e.title;
  final name = '$seriesName - S${e.season}E${e.number.toString().padLeft(2, '0')}';
  final ref = 'series:$seriesId';
  return Channel(
    id: Channel.stableId(tvgId: ref, name: name, url: url),
    name: title.startsWith(seriesName) ? title : '$name  $title',
    url: url,
    logo: cover,
    group: 'Series',
    tvgId: ref,
  );
}

/// Series id from an episode's tvgId (`series:123`), or null.
int? seriesIdOf(Channel media) =>
    media.tvgId.startsWith('series:') ? int.tryParse(media.tvgId.substring(7)) : null;

/// Series name from an episode's display name ("Show - S1E04  Title").
String seriesNameOf(Channel media) {
  final m = RegExp(r'^(.*?) - S\d+E\d+').firstMatch(media.name);
  return m?.group(1) ?? media.name;
}

/// Episode id from its url (`.../series/U/P/12345.mkv`).
String? episodeIdOf(Channel media) => RegExp(r'/series/[^/]+/[^/]+/([^/.]+)\.').firstMatch(media.url)?.group(1);

/// The episode after [current] (next in the season, else first of the next season).
Episode? nextEpisode(List<Episode> all, String currentId) {
  final i = all.indexWhere((e) => e.id == currentId);
  return i < 0 || i + 1 >= all.length ? null : all[i + 1];
}
