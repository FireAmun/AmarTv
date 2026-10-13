import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../channels/channel_filter.dart';
import '../channels/widgets.dart';
import '../movies/movies_page.dart';
import '../playlist/channel.dart';
import '../series/series_page.dart';
import '../vod/catalog_page.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';

/// One search box for live channels, movies and series.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.onPlay});
  final PlayMedia onPlay;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const perSection = 20;
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Every word must appear (so "bein 1 hd" finds "beIN SPORTS 1 HD").
  static bool _matches(String name, List<String> words) {
    final n = name.toLowerCase();
    return words.every(n.contains);
  }

  Widget _header(String text, int count, {bool loading = false}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(children: [
          Text(text.toUpperCase(),
              style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, letterSpacing: 1)),
          const SizedBox(width: 8),
          if (loading)
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Text(count > perSection ? '$perSection of $count' : '$count',
                style: const TextStyle(color: AppColors.textDim)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final hasVod = ref.watch(xtreamApiProvider) != null;
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final searching = words.isNotEmpty && words.join().length >= 2;

    final channels = searching
        ? ref.watch(allowedChannelsProvider).where((c) => _matches(c.name, words)).toList()
        : const <Channel>[];
    final movies = hasVod && searching ? ref.watch(moviesProvider) : const AsyncValue<List<MovieItem>>.data([]);
    final series = hasVod && searching ? ref.watch(seriesListProvider) : const AsyncValue<List<SeriesItem>>.data([]);
    final movieHits = (movies.valueOrNull ?? const <MovieItem>[]).where((m) => _matches(m.name, words)).toList();
    final seriesHits = (series.valueOrNull ?? const <SeriesItem>[]).where((s) => _matches(s.name, words)).toList();
    final api = ref.watch(xtreamApiProvider);

    return BackKeys(
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Search channels, movies, series',
              border: InputBorder.none,
            ),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), () => setState(() => _query = v));
            },
          ),
        ),
        body: !searching
            ? const VodMessage('Type at least 2 letters')
            : ListView(
                children: [
                  _header('Live channels', channels.length),
                  for (final c in channels.take(perSection))
                    ListTile(
                      leading: ChannelLogo(channel: c, size: 40),
                      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(groupLabel(c.group), maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text('${c.number}', style: const TextStyle(color: AppColors.textDim)),
                      onTap: () => widget.onPlay(context, c),
                    ),
                  if (hasVod) ...[
                    _header('Movies', movieHits.length, loading: movies.isLoading),
                    for (final m in movieHits.take(perSection))
                      CoverTile(
                        title: m.name,
                        subtitle: m.year,
                        cover: m.cover,
                        onTap: () => widget.onPlay(context, MoviesPage.mediaFor(api!, m)),
                      ),
                    _header('Series', seriesHits.length, loading: series.isLoading),
                    for (final s in seriesHits.take(perSection))
                      CoverTile(
                        title: s.name,
                        subtitle: s.year,
                        cover: s.cover,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => SeriesDetailPage(series: s, onPlay: widget.onPlay),
                        )),
                      ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }
}
