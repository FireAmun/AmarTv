import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../playlist/channel.dart';
import '../playlist/playlist_controller.dart';

enum ListMode { all, favorites, recent }

class ChannelFilter {
  const ChannelFilter({this.mode = ListMode.all, this.group, this.query = ''});

  final ListMode mode;

  /// null = all groups.
  final String? group;
  final String query;

  ChannelFilter copyWith({ListMode? mode, String? group, bool clearGroup = false, String? query}) =>
      ChannelFilter(
        mode: mode ?? this.mode,
        group: clearGroup ? null : (group ?? this.group),
        query: query ?? this.query,
      );
}

class ChannelFilterController extends Notifier<ChannelFilter> {
  @override
  ChannelFilter build() => const ChannelFilter();

  void setMode(ListMode mode) => state = state.copyWith(mode: mode);
  void setGroup(String? group) => state = state.copyWith(group: group, clearGroup: group == null);
  void setQuery(String query) => state = state.copyWith(query: query);
}

final channelFilterProvider =
    NotifierProvider<ChannelFilterController, ChannelFilter>(ChannelFilterController.new);

const ungroupedLabel = 'Other';

String groupLabel(String group) => group.isEmpty ? ungroupedLabel : group;

/// Channels minus hidden groups, in playlist order.
final allowedChannelsProvider = Provider<List<Channel>>((ref) {
  final channels = ref.watch(playlistProvider.select((s) => s.channels));
  final hidden = ref.watch(settingsProvider.select((s) => s.hiddenGroups));
  if (hidden.isEmpty) return channels;
  return channels.where((c) => !hidden.contains(c.group)).toList(growable: false);
});

/// Visible groups in playlist order.
final groupsProvider = Provider<List<String>>((ref) {
  final seen = <String>{};
  for (final c in ref.watch(allowedChannelsProvider)) {
    seen.add(c.group);
  }
  return seen.toList(growable: false);
});

/// Every group in the playlist (for the "hide groups" setting).
final allGroupsProvider = Provider<List<String>>((ref) {
  final seen = <String>{};
  for (final c in ref.watch(playlistProvider.select((s) => s.channels))) {
    seen.add(c.group);
  }
  return seen.toList(growable: false);
});

/// The list currently shown (mode + group + search applied).
final visibleChannelsProvider = Provider<List<Channel>>((ref) {
  final filter = ref.watch(channelFilterProvider);
  final allowed = ref.watch(allowedChannelsProvider);

  Iterable<Channel> list;
  switch (filter.mode) {
    case ListMode.all:
      list = allowed;
    case ListMode.favorites:
      // In the user's order; favorites in hidden groups stay visible.
      final byId = ref.watch(channelsByIdProvider);
      list = [
        for (final id in ref.watch(favoritesProvider))
          if (byId[id] != null) byId[id]!,
      ];
    case ListMode.recent:
      final byId = {for (final c in allowed) c.id: c};
      list = [
        for (final id in ref.watch(historyProvider))
          if (byId[id] != null) byId[id]!,
      ];
  }

  if (filter.group != null) list = list.where((c) => c.group == filter.group);

  final q = filter.query.trim().toLowerCase();
  if (q.isNotEmpty) {
    final asNumber = int.tryParse(q);
    list = list.where((c) => c.name.toLowerCase().contains(q) || (asNumber != null && c.number == asNumber));
  }
  return list.toList(growable: false);
});
