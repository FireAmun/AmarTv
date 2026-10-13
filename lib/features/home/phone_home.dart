import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../channels/channel_filter.dart';
import '../channels/group_setup_page.dart';
import '../channels/widgets.dart';
import '../movies/movies_page.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';
import '../player/track_pickers.dart';
import '../playlist/channel.dart';
import '../playlist/playlist_controller.dart';
import '../remote/remote_page.dart';
import '../search/search_page.dart';
import '../series/series_page.dart';
import '../settings/app_settings.dart';
import '../settings/settings_page.dart';
import '../xtream/xtream_api.dart';

/// Phone layout: bottom navigation (All / Favorites / Recent / Movies / Series / Settings).
class PhoneHome extends ConsumerStatefulWidget {
  const PhoneHome({super.key, this.openSettingsOnStart = false});
  final bool openSettingsOnStart;

  @override
  ConsumerState<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends ConsumerState<PhoneHome> {
  static const _settingsTab = 3;
  late int _tab = widget.openSettingsOnStart ? _settingsTab : 0;
  bool _groupSetupShown = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(playlistProvider.select((s) => s.channels), (_, channels) {
      if (channels.isEmpty || _groupSetupShown) return;
      if (ref.read(settingsProvider).groupsConfigured || ref.read(allGroupsProvider).length <= 12) return;
      _groupSetupShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GroupSetupPage(firstRun: true)));
        }
      });
    }, fireImmediately: true);
  }

  /// Movies and Series open as pages; the other entries are tabs.
  void _select(_Nav nav) {
    void onPlay(BuildContext ctx, Channel media) => openPhonePlayer(ctx, ref, media);
    switch (nav) {
      case _Nav.movies:
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MoviesPage(onPlay: onPlay)));
      case _Nav.series:
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SeriesPage(onPlay: onPlay)));
      case _Nav.settings:
        setState(() => _tab = _settingsTab);
      case _Nav.all || _Nav.favorites || _Nav.recent:
        setState(() => _tab = nav.index);
        ref.read(channelFilterProvider.notifier).setMode(ListMode.values[nav.index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final warning = ref.read(appPathsProvider).warning;
    final hasVod = ref.watch(xtreamApiProvider) != null;
    final navs = [
      _Nav.all, _Nav.favorites, _Nav.recent, //
      if (hasVod) ...[_Nav.movies, _Nav.series],
      _Nav.settings,
    ];
    final current = _tab == _settingsTab ? _Nav.settings : _Nav.values[_tab];
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == _settingsTab ? 'Settings' : 'AmarTv'),
        actions: [
          IconButton(
            tooltip: 'Search everything',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SearchPage(onPlay: (ctx, media) => openPhonePlayer(ctx, ref, media)),
            )),
          ),
          IconButton(
            tooltip: 'Use as remote for a PC',
            icon: const Icon(Icons.settings_remote_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemotePage())),
          ),
        ],
      ),
      body: Column(
        children: [
          PlaylistBanner(extraWarning: warning),
          Expanded(child: _tab == _settingsTab ? const _SettingsTab() : const _ChannelsTab()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navs.indexOf(current),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        onDestinationSelected: (i) => _select(navs[i]),
        destinations: [
          for (final n in navs) NavigationDestination(icon: Icon(n.icon), label: n.label),
        ],
      ),
    );
  }
}

enum _Nav {
  all('All', Icons.live_tv_outlined),
  favorites('Favorites', Icons.star_border_rounded),
  recent('Recent', Icons.history),
  movies('Movies', Icons.movie_outlined),
  series('Series', Icons.video_library_outlined),
  settings('Settings', Icons.settings_outlined);

  const _Nav(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _ChannelsTab extends ConsumerStatefulWidget {
  const _ChannelsTab();

  @override
  ConsumerState<_ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends ConsumerState<_ChannelsTab> {
  final _search = TextEditingController(text: '');
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(channelFilterProvider).query;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channels = ref.watch(visibleChannelsProvider);
    final groups = ref.watch(groupsProvider);
    final filter = ref.watch(channelFilterProvider);
    final selected = filter.group;
    const scale = UiScale(false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search channels',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300),
                  () => ref.read(channelFilterProvider.notifier).setQuery(v));
            },
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: groups.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final g = i == 0 ? null : groups[i - 1];
              return ChoiceChip(
                label: Text(g == null ? 'All' : groupLabel(g)),
                selected: g == selected,
                showCheckmark: false,
                onSelected: (_) => ref.read(channelFilterProvider.notifier).setGroup(g),
              );
            },
          ),
        ),
        Expanded(
          child: ChannelListView(
            channels: channels,
            scale: scale,
            onSelect: (c) => openPhonePlayer(context, ref, c),
            // Favorites: long-press and drag to reorder.
            reorderable: filter.mode == ListMode.favorites && filter.group == null && filter.query.isEmpty,
          ),
        ),
      ],
    );
  }
}

/// Settings tab; with a parental PIN it shows an unlock button that asks for
/// the PIN and opens Settings as a page.
class _SettingsTab extends ConsumerWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPin = ref.watch(settingsProvider.select((s) => s.pin.isNotEmpty));
    if (!hasPin) return const SettingsPage(embedded: true);
    return Center(
      child: FilledButton.icon(
        icon: const Icon(Icons.lock_open),
        label: const Text('Unlock settings'),
        onPressed: () => openSettings(context, ref),
      ),
    );
  }
}

Future<void> openPhonePlayer(BuildContext context, WidgetRef ref, Channel channel) async {
  unawaited(ref.read(playerProvider.notifier).play(channel));
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhonePlayerPage()));
}

/// Fullscreen landscape player. Leaving the page stops playback; going to the
/// background releases the stream and resumes it on return.
class PhonePlayerPage extends ConsumerStatefulWidget {
  const PhonePlayerPage({super.key});

  @override
  ConsumerState<PhonePlayerPage> createState() => _PhonePlayerPageState();
}

class _PhonePlayerPageState extends ConsumerState<PhonePlayerPage> with WidgetsBindingObserver {
  late final PlayerController _player = ref.read(playerProvider.notifier);
  bool _controls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hide?.cancel();
    // Provider state can't change while the tree is being torn down.
    Future.microtask(_player.stop);
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _player.suspend();
      case AppLifecycleState.resumed:
        _player.resume();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  void _step(int delta) {
    final list = ref.read(visibleChannelsProvider);
    final current = ref.read(playerProvider).channel;
    if (list.isEmpty) return;
    final idx = current == null ? -1 : list.indexWhere((c) => c.id == current.id);
    _player.play(list[(idx + delta) % list.length]);
    _scheduleHide();
  }

  void _seek(int seconds) {
    _player.seekBy(Duration(seconds: seconds));
    _scheduleHide();
  }

  void _zoom() {
    ref.read(settingsProvider.notifier).update(
        (s) => s.copyWith(zoom: ZoomMode.values[(s.zoom.index + 1) % ZoomMode.values.length]));
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PlayerView(scale: const UiScale(false), showControls: _controls),
            if (_controls) ...[
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
                      Expanded(
                        child: Text(
                          state.channel == null ? '' : '${state.channel!.number}  ${state.channel!.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: state.isVod
                        ? [
                            IconButton(icon: const Icon(Icons.replay_10), onPressed: () => _seek(-10)),
                            IconButton(
                              icon: Icon(state.paused ? Icons.play_arrow : Icons.pause),
                              onPressed: () {
                                _player.togglePause();
                                _scheduleHide();
                              },
                            ),
                            IconButton(icon: const Icon(Icons.forward_30), onPressed: () => _seek(30)),
                            IconButton(
                              icon: const Icon(Icons.closed_caption_outlined),
                              onPressed: () => showSubtitlePicker(context, ref),
                            ),
                            IconButton(icon: const Icon(Icons.aspect_ratio), onPressed: _zoom),
                          ]
                        : [
                            IconButton(icon: const Icon(Icons.skip_previous), onPressed: () => _step(-1)),
                            IconButton(
                              icon: Icon(state.muted ? Icons.volume_off : Icons.volume_up),
                              onPressed: _player.toggleMute,
                            ),
                            IconButton(icon: const Icon(Icons.refresh), onPressed: _player.retry),
                            IconButton(icon: const Icon(Icons.aspect_ratio), onPressed: _zoom),
                            IconButton(icon: const Icon(Icons.skip_next), onPressed: () => _step(1)),
                          ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
