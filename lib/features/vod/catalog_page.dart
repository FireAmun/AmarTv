import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logo_cache.dart';
import '../../core/theme.dart';
import '../../core/url_mask.dart';
import '../playlist/channel.dart';
import '../xtream/xtream_models.dart';

/// Called with a playable item (movie or episode).
typedef PlayMedia = void Function(BuildContext context, Channel media);

/// Esc / Backspace / Back close the page (keyboard and remote users).
class BackKeys extends StatelessWidget {
  const BackKeys({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
          const SingleActivator(LogicalKeyboardKey.backspace): () => Navigator.maybePop(context),
          const SingleActivator(LogicalKeyboardKey.goBack): () => Navigator.maybePop(context),
        },
        // No extra FocusScope here: it would take the focus and the
        // autofocused first item would never get it (keyboard/remote users).
        child: child,
      );
}

/// Browse a big catalogue (movies, series): categories + search + covers.
/// Wide screens show categories on the left, phones show them as chips.
class CatalogPage<T> extends StatefulWidget {
  const CatalogPage({
    super.key,
    required this.title,
    required this.categories,
    required this.items,
    required this.nameOf,
    required this.categoryOf,
    required this.coverOf,
    required this.subtitleOf,
    required this.onOpen,
    required this.onRetry,
    this.header,
    this.headerHasItems = false,
    this.extraOf,
  });

  final String title;
  final AsyncValue<List<SeriesCategory>> categories;
  final AsyncValue<List<T>> items;
  final String Function(T item) nameOf;
  final String Function(T item) categoryOf;
  final String Function(T item) coverOf;
  final String? Function(T item) subtitleOf;
  final void Function(BuildContext context, T item) onOpen;
  final VoidCallback onRetry;

  /// Shown above the list when no category/search is active ("Continue watching").
  final Widget? header;

  /// The header shows something focusable (it then gets the first focus).
  final bool headerHasItems;

  /// Optional widget under an item's title (e.g. resume progress).
  final Widget? Function(T item)? extraOf;

  @override
  State<CatalogPage<T>> createState() => _CatalogPageState<T>();
}

class _CatalogPageState<T> extends State<CatalogPage<T>> {
  String? _category;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final lower = widget.title.toLowerCase();

    Widget body;
    if (widget.items.isLoading || widget.categories.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (widget.items.hasError) {
      body = VodMessage(maskUrl('Could not load $lower.\n${widget.items.error}'), onRetry: widget.onRetry);
    } else {
      final cats = widget.categories.valueOrNull ?? const [];
      final q = _query.trim().toLowerCase();
      final items = (widget.items.valueOrNull ?? const [])
          .where((i) => _category == null || widget.categoryOf(i) == _category)
          .where((i) => q.isEmpty || widget.nameOf(i).toLowerCase().contains(q))
          .toList();

      final showHeader = widget.header != null && _category == null && q.isEmpty;
      final list = items.isEmpty && !showHeader
          ? VodMessage('No $lower')
          : CustomScrollView(
              slivers: [
                if (showHeader) SliverToBoxAdapter(child: widget.header),
                SliverFixedExtentList(
                  itemExtent: 80,
                  delegate: SliverChildBuilderDelegate(
                    childCount: items.length,
                    (context, i) => CoverTile(
                      title: widget.nameOf(items[i]),
                      subtitle: widget.subtitleOf(items[i]),
                      cover: widget.coverOf(items[i]),
                      extra: widget.extraOf?.call(items[i]),
                      autofocus: i == 0 && !(showHeader && widget.headerHasItems),
                      onTap: () => widget.onOpen(context, items[i]),
                    ),
                  ),
                ),
              ],
            );

      void pick(String? id) => setState(() => _category = id);
      if (wide) {
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 240,
              child: ListView(
                children: [
                  CategoryTile(label: 'All $lower', selected: _category == null, onTap: () => pick(null)),
                  for (final c in cats) CategoryTile(label: c.name, selected: _category == c.id, onTap: () => pick(c.id)),
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
                  VodChip(label: 'All', selected: _category == null, onTap: () => pick(null)),
                  for (final c in cats) VodChip(label: c.name, selected: _category == c.id, onTap: () => pick(c.id)),
                ],
              ),
            ),
            Expanded(child: list),
          ],
        );
      }
    }

    return BackKeys(
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search $lower',
                  border: const OutlineInputBorder(),
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

/// Poster / logo image from the bounded logo cache.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(Icons.movie_outlined, size: 32);
    if (url.isEmpty) return fallback;
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: LogoCache.manager,
      memCacheWidth: 96,
      fit: BoxFit.cover,
      fadeInDuration: Duration.zero,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

class CoverTile extends StatelessWidget {
  const CoverTile({
    super.key,
    required this.title,
    required this.cover,
    required this.onTap,
    this.subtitle,
    this.extra,
    this.autofocus = false,
  });
  final String title;
  final String? subtitle;
  final String cover;
  final VoidCallback onTap;

  /// Shown under the subtitle, e.g. a resume progress bar.
  final Widget? extra;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    return ListTile(
      autofocus: autofocus,
      leading: SizedBox(
        width: 44,
        height: 60,
        child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CoverImage(url: cover)),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: extra ?? (hasSubtitle ? Text(subtitle!) : null),
      onTap: onTap,
    );
  }
}

class CategoryTile extends StatelessWidget {
  const CategoryTile({super.key, required this.label, required this.selected, required this.onTap});
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

class VodChip extends StatelessWidget {
  const VodChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(label: Text(label), selected: selected, showCheckmark: false, onSelected: (_) => onTap()),
      );
}

class VodMessage extends StatelessWidget {
  const VodMessage(this.text, {super.key, this.onRetry});
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
