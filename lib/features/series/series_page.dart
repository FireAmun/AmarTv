import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logo_cache.dart';
import '../../core/theme.dart';
import '../../core/url_mask.dart';
import '../playlist/channel.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';

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

/// Called with a playable item built from an episode.
typedef PlayMedia = void Function(BuildContext context, Channel media);

/// Esc / Backspace close the page (keyboard and remote users).
class _BackKeys extends StatelessWidget {
  const _BackKeys({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
          const SingleActivator(LogicalKeyboardKey.backspace): () => Navigator.maybePop(context),
          const SingleActivator(LogicalKeyboardKey.goBack): () => Navigator.maybePop(context),
        },
        child: FocusScope(autofocus: true, child: child),
      );
}

class SeriesPage extends ConsumerStatefulWidget {
  const SeriesPage({super.key, required this.onPlay});
  final PlayMedia onPlay;

  @override
  ConsumerState<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends ConsumerState<SeriesPage> {
  String? _category;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(seriesCategoriesProvider);
    final series = ref.watch(seriesListProvider);
    final wide = MediaQuery.sizeOf(context).width >= 760;

    Widget body;
    if (series.isLoading || categories.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (series.hasError) {
      body = _Message(maskUrl('Could not load series.\n${series.error}'), onRetry: () => ref.invalidate(seriesListProvider));
    } else {
      final cats = categories.valueOrNull ?? const [];
      final q = _query.trim().toLowerCase();
      final items = (series.valueOrNull ?? const <SeriesItem>[])
          .where((s) => _category == null || s.categoryId == _category)
          .where((s) => q.isEmpty || s.name.toLowerCase().contains(q))
          .toList();

      final list = items.isEmpty
          ? const _Message('No series')
          : ListView.builder(
              itemCount: items.length,
              itemExtent: 76,
              itemBuilder: (context, i) => _SeriesTile(
                item: items[i],
                autofocus: i == 0,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => SeriesDetailPage(series: items[i], onPlay: widget.onPlay),
                )),
              ),
            );

      if (wide) {
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 240,
              child: ListView(
                children: [
                  _CategoryTile(label: 'All series', selected: _category == null, onTap: () => setState(() => _category = null)),
                  for (final c in cats)
                    _CategoryTile(label: c.name, selected: _category == c.id, onTap: () => setState(() => _category = c.id)),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: list),
          ],
        );
      } else {
        body = Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _Chip(label: 'All', selected: _category == null, onTap: () => setState(() => _category = null)),
                  for (final c in cats)
                    _Chip(label: c.name, selected: _category == c.id, onTap: () => setState(() => _category = c.id)),
                ],
              ),
            ),
            Expanded(child: list),
          ],
        );
      }
    }

    return _BackKeys(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Series'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search series',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
        ),
        body: body,
      ),
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

  Channel _media(Episode e) {
    final api = ref.read(xtreamApiProvider)!;
    final url = api.episodeUrl(e);
    final title = e.title.isEmpty ? 'Episode ${e.number}' : e.title;
    final name = '${widget.series.name} - S${e.season}E${e.number.toString().padLeft(2, '0')}';
    return Channel(
      id: Channel.stableId(tvgId: 'series:${widget.series.id}', name: name, url: url),
      name: title.startsWith(widget.series.name) ? title : '$name  $title',
      url: url,
      logo: widget.series.cover,
      group: 'Series',
    );
  }

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(seriesEpisodesProvider(widget.series.id));
    return _BackKeys(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.series.name)),
        body: episodes.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Message(maskUrl('Could not load episodes.\n$e'),
              onRetry: () => ref.invalidate(seriesEpisodesProvider(widget.series.id))),
          data: (all) {
            if (all.isEmpty) return const _Message('No episodes');
            final seasons = {for (final e in all) e.season}.toList()..sort();
            final season = _season ?? seasons.first;
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
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      for (final s in seasons)
                        _Chip(label: 'Season $s', selected: s == season, onTap: () => setState(() => _season = s)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final e = list[i];
                      final minutes = e.duration == null ? '' : '  -  ${e.duration!.inMinutes} min';
                      return ListTile(
                        autofocus: i == 0,
                        leading: CircleAvatar(child: Text('${e.number}')),
                        title: Text(e.title.isEmpty ? 'Episode ${e.number}' : e.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('S${e.season} E${e.number}$minutes'),
                        onTap: () => widget.onPlay(context, _media(e)),
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

class _SeriesTile extends StatelessWidget {
  const _SeriesTile({required this.item, required this.onTap, this.autofocus = false});
  final SeriesItem item;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final cover = item.cover.isEmpty
        ? const Icon(Icons.movie_outlined, size: 32)
        : CachedNetworkImage(
            imageUrl: item.cover,
            cacheManager: LogoCache.manager,
            memCacheWidth: 96,
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => const Icon(Icons.movie_outlined, size: 32),
          );
    return ListTile(
      autofocus: autofocus,
      leading: SizedBox(width: 44, height: 60, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: cover)),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.year.isEmpty ? null : Text(item.year),
      onTap: onTap,
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: AppColors.surfaceHigh,
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(label: Text(label), selected: selected, showCheckmark: false, onSelected: (_) => onTap()),
      );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ]),
        ),
      );
}
