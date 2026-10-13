import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/url_mask.dart';
import '../playlist/channel.dart';
import '../vod/catalog_page.dart';
import '../vod/episode_media.dart';
import '../vod/resume.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';

export '../vod/catalog_page.dart' show PlayMedia;

final seriesCategoriesProvider = FutureProvider<List<SeriesCategory>>((ref) async {
  final api = ref.watch(xtreamApiProvider);
  return api == null ? const [] : api.seriesCategories();
});

final seriesListProvider = FutureProvider<List<SeriesItem>>((ref) async {
  final api = ref.watch(xtreamApiProvider);
  return api == null ? const [] : api.seriesList();
});

final seriesEpisodesProvider = FutureProvider.autoDispose.family<List<Episode>, int>((ref, id) async {
  final api = ref.watch(xtreamApiProvider);
  return api == null ? const [] : api.seriesEpisodes(id);
});

class SeriesPage extends ConsumerWidget {
  const SeriesPage({super.key, required this.onPlay});
  final PlayMedia onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CatalogPage<SeriesItem>(
      title: 'Series',
      categories: ref.watch(seriesCategoriesProvider),
      items: ref.watch(seriesListProvider),
      nameOf: (s) => s.name,
      categoryOf: (s) => s.categoryId,
      coverOf: (s) => s.cover,
      subtitleOf: (s) => s.year,
      header: ContinueWatching(refPrefix: 'series:', onPlay: onPlay),
      headerHasItems:
          ref.watch(resumeListProvider).valueOrNull?.any((p) => p.ref.startsWith('series:') && !p.watched) ?? false,
      onOpen: (context, s) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SeriesDetailPage(series: s, onPlay: onPlay),
      )),
      onRetry: () => ref.invalidate(seriesListProvider),
    );
  }
}

class SeriesDetailPage extends ConsumerStatefulWidget {
  const SeriesDetailPage({super.key, required this.series, required this.onPlay});
  final SeriesItem series;
  final PlayMedia onPlay;

  @override
  ConsumerState<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends ConsumerState<SeriesDetailPage> {
  int? _season;

  Channel _media(Episode e) => episodeMedia(ref.read(xtreamApiProvider)!,
      seriesId: widget.series.id, seriesName: widget.series.name, cover: widget.series.cover, e: e);

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(seriesEpisodesProvider(widget.series.id));
    final resume = ref.watch(resumeByIdProvider);
    return BackKeys(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.series.name)),
        body: episodes.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => VodMessage(maskUrl('Could not load episodes.\n$e'),
              onRetry: () => ref.invalidate(seriesEpisodesProvider(widget.series.id))),
          data: (all) {
            if (all.isEmpty) return const VodMessage('No episodes');
            final media = {for (final e in all) e.id: _media(e)};
            final seasons = {for (final e in all) e.season}.toList()..sort();

            // The episode to offer: the one you were watching, or - if you
            // finished it - the one after it.
            final started = all.where((e) => resume.containsKey(media[e.id]!.id)).toList()
              ..sort((a, b) => resume[media[b.id]!.id]!.updatedAt.compareTo(resume[media[a.id]!.id]!.updatedAt));
            Episode? target;
            var label = '';
            if (started.isNotEmpty) {
              final last = started.first;
              final saved = resume[media[last.id]!.id]!;
              if (!saved.watched) {
                target = last;
                label = 'Continue S${last.season} E${last.number}  -  ${formatDuration(saved.position)}';
              } else {
                target = nextEpisode(all, last.id);
                if (target != null) label = 'Play next: S${target.season} E${target.number}';
              }
            }
            // Open on that episode's season.
            final season = _season ?? target?.season ?? (started.isNotEmpty ? started.first.season : seasons.first);
            final list = all.where((e) => e.season == season).toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.series.plot.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(widget.series.plot,
                        maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim)),
                  ),
                if (target != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: FilledButton.icon(
                      autofocus: true,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(label),
                      onPressed: () => widget.onPlay(context, media[target!.id]!),
                    ),
                  ),
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      for (final s in seasons)
                        VodChip(label: 'Season $s', selected: s == season, onTap: () => setState(() => _season = s)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final e = list[i];
                      final m = media[e.id]!;
                      final saved = resume[m.id];
                      final minutes = e.duration == null ? '' : '  -  ${e.duration!.inMinutes} min';
                      return ListTile(
                        autofocus: i == 0 && target == null,
                        leading: CircleAvatar(child: Text('${e.number}')),
                        title: Text(e.title.isEmpty ? 'Episode ${e.number}' : e.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: saved == null ? Text('S${e.season} E${e.number}$minutes') : ResumeProgress(position: saved),
                        onTap: () => widget.onPlay(context, m),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
