import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logo_cache.dart';
import '../../core/theme.dart';
import '../player/player_controller.dart';
import '../playlist/channel.dart';
import '../playlist/playlist_controller.dart';
import '../xtream/epg.dart';
import '../xtream/xtream_api.dart';
import 'channel_filter.dart';

class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.channel, required this.size});
  final Channel channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(name: channel.name, size: size);
    if (channel.logo.isEmpty) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox.square(
      dimension: size,
      child: CachedNetworkImage(
        imageUrl: channel.logo,
        cacheManager: LogoCache.manager,
        // Decode small: keeps memory low with thousands of logos.
        memCacheWidth: (size * dpr).round(),
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(letter, style: TextStyle(fontSize: size * 0.42, color: AppColors.textDim)),
    );
  }
}

/// Lazy channel list with fixed row height (cheap layout, easy keyboard
/// scrolling). [highlightIndex] draws the keyboard focus. With [reorderable]
/// (Favorites) rows can be dragged into a new order.
class ChannelListView extends ConsumerWidget {
  const ChannelListView({
    super.key,
    required this.channels,
    required this.onSelect,
    required this.scale,
    this.highlightIndex,
    this.controller,
    this.reorderable = false,
    this.positionNumbers = false,
  });

  final List<Channel> channels;
  final ValueChanged<Channel> onSelect;
  final UiScale scale;
  final int? highlightIndex;
  final ScrollController? controller;
  final bool reorderable;

  /// Show 1..N (favorite quick numbers) instead of channel numbers.
  final bool positionNumbers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    final playingId = ref.watch(playerProvider.select((s) => s.channel?.id));
    if (channels.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No channels', style: TextStyle(color: AppColors.textDim)),
        ),
      );
    }
    Widget tile(int i) {
      final c = channels[i];
      return ChannelTile(
        key: ValueKey(c.id),
        channel: c,
        scale: scale,
        displayNumber: positionNumbers ? i + 1 : c.number,
        highlighted: i == highlightIndex,
        playing: c.id == playingId,
        favorite: favorites.contains(c.id),
        onTap: () => onSelect(c),
        onFavorite: () => ref.read(favoritesProvider.notifier).toggle(c.id),
        allowLongPress: !reorderable,
      );
    }

    if (reorderable) {
      return ReorderableListView.builder(
        scrollController: controller,
        itemCount: channels.length,
        itemExtent: scale.tileHeight,
        onReorder: (from, to) {
          // ReorderableListView reports the slot *before* removal.
          ref.read(favoritesProvider.notifier).reorder(from, to > from ? to - 1 : to);
        },
        itemBuilder: (context, i) => tile(i),
      );
    }
    return ListView.builder(
      controller: controller,
      itemCount: channels.length,
      itemExtent: scale.tileHeight,
      itemBuilder: (context, i) => tile(i),
    );
  }
}

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.channel,
    required this.scale,
    required this.displayNumber,
    required this.highlighted,
    required this.playing,
    required this.favorite,
    required this.onTap,
    required this.onFavorite,
    this.allowLongPress = true,
  });

  final Channel channel;
  final UiScale scale;
  final int displayNumber;
  final bool highlighted;
  final bool playing;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final bool allowLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: playing ? AppColors.accent.withValues(alpha: 0.18) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: allowLongPress ? onFavorite : null,
        // Keyboard focus is drawn via [highlighted]; one key handler owns keys.
        canRequestFocus: false,
        child: Container(
          decoration: highlighted
              ? BoxDecoration(border: Border.all(color: AppColors.focus, width: 3))
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              SizedBox(
                width: scale.tv ? 64 : 46,
                child: Text(
                  displayNumber > 0 ? '$displayNumber' : '',
                  style: const TextStyle(color: AppColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
              ChannelLogo(channel: channel, size: scale.logoSize),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: playing ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    EpgNowLine(channel: channel),
                  ],
                ),
              ),
              ExcludeFocus(
                child: IconButton(
                  tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                  onPressed: onFavorite,
                  icon: Icon(
                    favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    color: favorite ? AppColors.focus : AppColors.textDim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small banner for offline / refresh errors / portable-path warnings.
class PlaylistBanner extends ConsumerWidget {
  const PlaylistBanner({super.key, this.extraWarning});
  final String? extraWarning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playlistProvider);
    String? text;
    var color = AppColors.surfaceHigh;
    if (s.offline) {
      text = 'Offline - showing saved channels. Retrying every 30 s.';
    } else if (s.error != null) {
      text = s.error;
      color = AppColors.danger.withValues(alpha: 0.25);
    } else if (s.refreshing && s.channels.isEmpty) {
      text = 'Loading playlist...';
    } else if (extraWarning != null) {
      text = extraWarning;
    } else {
      final account = ref.watch(accountProvider).valueOrNull;
      final left = account?.remaining;
      if (account != null && !account.isActive) {
        text = 'Subscription status: ${account.status}';
        color = AppColors.danger.withValues(alpha: 0.25);
      } else if (left != null && left.inDays < 7) {
        text = left.isNegative ? 'Subscription expired' : 'Subscription expires in ${left.inDays} days';
        color = AppColors.danger.withValues(alpha: 0.25);
      }
    }
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(text, style: const TextStyle(fontSize: 13)),
    );
  }
}

/// All / Favorites / Recent switch (desktop).
class ModeTabs extends ConsumerWidget {
  const ModeTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(channelFilterProvider.select((f) => f.mode));
    return SegmentedButton<ListMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ListMode.all, label: Text('All')),
        ButtonSegment(value: ListMode.favorites, label: Text('Favorites')),
        ButtonSegment(value: ListMode.recent, label: Text('Recent')),
      ],
      selected: {mode},
      onSelectionChanged: (s) => ref.read(channelFilterProvider.notifier).setMode(s.first),
    );
  }
}
