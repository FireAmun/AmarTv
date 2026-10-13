import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playlist/channel.dart';
import '../vod/catalog_page.dart';
import '../vod/resume.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';

final movieCategoriesProvider = FutureProvider<List<SeriesCategory>>((ref) async {
  final api = ref.watch(xtreamApiProvider);
  return api == null ? const [] : api.movieCategories();
});

final moviesProvider = FutureProvider<List<MovieItem>>((ref) async {
  final api = ref.watch(xtreamApiProvider);
  return api == null ? const [] : api.movies();
});

/// Movies (Xtream VOD): categories, search, Continue watching; tap to play
/// (resumes where you stopped).
class MoviesPage extends ConsumerWidget {
  const MoviesPage({super.key, required this.onPlay});
  final PlayMedia onPlay;

  static Channel mediaFor(XtreamApi api, MovieItem m) {
    final url = api.movieUrl(m);
    final ref0 = 'movie:${m.id}';
    return Channel(
      id: Channel.stableId(tvgId: ref0, name: m.name, url: url),
      name: m.name,
      url: url,
      logo: m.cover,
      group: 'Movies',
      tvgId: ref0,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(xtreamApiProvider);
    final resume = ref.watch(resumeByIdProvider);
    return CatalogPage<MovieItem>(
      title: 'Movies',
      categories: ref.watch(movieCategoriesProvider),
      items: ref.watch(moviesProvider),
      nameOf: (m) => m.name,
      categoryOf: (m) => m.categoryId,
      coverOf: (m) => m.cover,
      subtitleOf: (m) => [if (m.year.isNotEmpty) m.year, if (m.rating.isNotEmpty) '★ ${m.rating}'].join('   '),
      extraOf: (m) {
        if (api == null) return null;
        final saved = resume[mediaFor(api, m).id];
        return saved == null ? null : ResumeProgress(position: saved);
      },
      header: ContinueWatching(refPrefix: 'movie:', onPlay: onPlay),
      headerHasItems:
          ref.watch(resumeListProvider).valueOrNull?.any((p) => p.ref.startsWith('movie:') && !p.watched) ?? false,
      onOpen: (context, m) {
        if (api != null) onPlay(context, mediaFor(api, m));
      },
      onRetry: () => ref.invalidate(moviesProvider),
    );
  }
}
