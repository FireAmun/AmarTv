import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../channels/channel_filter.dart';
import '../channels/group_setup_page.dart';
import '../channels/widgets.dart';
import '../player/numeric_entry.dart';
import '../player/player_controller.dart';
import '../player/player_view.dart';
import '../playlist/channel.dart';
import '../playlist/playlist_controller.dart';
import '../remote/remote_server.dart';
import '../series/series_page.dart';
import '../settings/app_settings.dart';
import '../settings/settings_page.dart';
import '../xtream/xtream_api.dart';

/// Windows (and Android tablet) layout: groups + channel list on the left,
/// player on the right. Fullscreen shows only the player; the list becomes an
/// overlay. Keyboard, remote-control keys and the phone remote all end up in
/// [_run], the one place that decides what a command does.
class DesktopHome extends ConsumerStatefulWidget {
  const DesktopHome({super.key, this.openSettingsOnStart = false});
  final bool openSettingsOnStart;

  @override
  ConsumerState<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends ConsumerState<DesktopHome> {
  static const cursorHideAfter = Duration(seconds: 3);
  static const overlayHideAfter = Duration(seconds: 8);

  final _rootFocus = FocusNode(debugLabel: 'root');
  final _searchFocus = FocusNode(debugLabel: 'search');
  final _search = TextEditingController();
  final _listScroll = ScrollController();
  late final NumericEntry _numeric = NumericEntry(onCommit: _tuneNumber);
  StreamSubscription<String>? _remoteSub;

  bool _fullscreen = false;

  /// Keyboard is in the channel list (overlay open when fullscreen).
  bool _listOpen = false;
  int _highlight = 0;
  bool _cursorVisible = true;
  String? _notice;
  int _infoTick = 0;

  Timer? _idleTimer;
  Timer? _overlayTimer;
  Timer? _noticeTimer;
  Timer? _searchDebounce;
  bool _autoPlayed = false;
  bool _groupSetupShown = false;

  bool get _isWindows => Platform.isWindows;
  bool get _tv => _isWindows && ref.read(settingsProvider).tvMode;

  @override
  void initState() {
    super.initState();
    // main() switches the window to fullscreen in TV mode.
    _fullscreen = _tv;
    ref.listenManual(playlistProvider.select((s) => s.channels), (_, channels) => _onChannels(channels),
        fireImmediately: true);
    _remoteSub = ref.read(remoteCommandsProvider).stream.listen(_onRemote);
    if (widget.openSettingsOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings());
    }
    _bumpIdle();
  }

  @override
  void dispose() {
    _remoteSub?.cancel();
    _numeric.dispose();
    _idleTimer?.cancel();
    _overlayTimer?.cancel();
    _noticeTimer?.cancel();
    _searchDebounce?.cancel();
    _rootFocus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  void _onChannels(List<Channel> channels) {
    if (channels.isEmpty) return;
    // TV mode: auto-play the last watched channel once the playlist is known.
    if (!_autoPlayed) {
      _autoPlayed = true;
      final last = ref.read(channelsByIdProvider)[ref.read(settingsProvider).lastChannelId];
      if (last != null && _tv && ref.read(playerProvider).channel == null) {
        ref.read(playerProvider.notifier).play(last);
      }
    }
    // First run with a big playlist: let the user pick groups.
    final settings = ref.read(settingsProvider);
    if (!_groupSetupShown && !settings.groupsConfigured && ref.read(allGroupsProvider).length > 12) {
      _groupSetupShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GroupSetupPage(firstRun: true)));
        if (mounted) _rootFocus.requestFocus();
      });
    }
  }

  // ------------------------------------------------------------------ input

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    _bumpIdle();
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    final keys = HardwareKeyboard.instance;

    // Typing in the search box: only Esc/Down leave it.
    if (_searchFocus.hasFocus) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.arrowDown) {
        _leaveSearch();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (keys.isControlPressed && key == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }

    // Favorites: Shift+Up/Down moves the highlighted favorite.
    if (keys.isShiftPressed && _listOpen && _favoritesMode &&
        (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
      _moveFavorite(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
      return KeyEventResult.handled;
    }

    final digit = _digitOf(key);
    if (digit != null) {
      if (!repeat) _run('d$digit');
      return KeyEventResult.handled;
    }

    final command = _commandFor(key);
    if (command == null) return KeyEventResult.ignored;
    // Holding a key repeats only navigation-type commands.
    const repeatable = {'up', 'down', 'left', 'right', 'pageup', 'pagedown', 'volup', 'voldown', 'chup', 'chdown'};
    if (!repeat || repeatable.contains(command)) _run(command);
    return KeyEventResult.handled;
  }

  /// Keyboard and remote-control keys -> command names (same names as the
  /// phone remote, see [RemoteServer.commands]).
  static String? _commandFor(LogicalKeyboardKey key) => _keyCommands[key];

  static final Map<LogicalKeyboardKey, String> _keyCommands = {
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
      LogicalKeyboardKey.pageUp: 'pageup',
      LogicalKeyboardKey.pageDown: 'pagedown',
      LogicalKeyboardKey.enter: 'ok',
      LogicalKeyboardKey.numpadEnter: 'ok',
      LogicalKeyboardKey.select: 'ok',
      LogicalKeyboardKey.escape: 'back',
      LogicalKeyboardKey.goBack: 'back',
      LogicalKeyboardKey.browserBack: 'back',
      LogicalKeyboardKey.backspace: 'last',
      LogicalKeyboardKey.keyF: 'fullscreen',
      LogicalKeyboardKey.keyM: 'mute',
      LogicalKeyboardKey.keyZ: 'zoom',
      LogicalKeyboardKey.keyI: 'info',
      LogicalKeyboardKey.info: 'info',
      LogicalKeyboardKey.keyS: 'series',
      LogicalKeyboardKey.tab: 'list',
      LogicalKeyboardKey.contextMenu: 'list',
      LogicalKeyboardKey.space: 'playpause',
      LogicalKeyboardKey.mediaPlayPause: 'playpause',
      LogicalKeyboardKey.mediaPlay: 'playpause',
      LogicalKeyboardKey.mediaPause: 'playpause',
      LogicalKeyboardKey.channelUp: 'chup',
      LogicalKeyboardKey.channelDown: 'chdown',
      LogicalKeyboardKey.mediaTrackNext: 'chup',
      LogicalKeyboardKey.mediaTrackPrevious: 'chdown',
      LogicalKeyboardKey.equal: 'volup',
      LogicalKeyboardKey.numpadAdd: 'volup',
      LogicalKeyboardKey.minus: 'voldown',
      LogicalKeyboardKey.numpadSubtract: 'voldown',
  };

  static int? _digitOf(LogicalKeyboardKey key) {
    const digits = [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, //
      LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad0, LogicalKeyboardKey.numpad1, LogicalKeyboardKey.numpad2, //
      LogicalKeyboardKey.numpad3, LogicalKeyboardKey.numpad4, LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6, LogicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final i = digits.indexOf(key);
    if (i >= 0) return i;
    final j = numpad.indexOf(key);
    return j >= 0 ? j : null;
  }

  void _onRemote(String command) {
    if (!mounted) return;
    _bumpIdle();
    // A page (Settings, Series) is open: the remote's Back closes it.
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      if (command == 'back') nav.maybePop();
      return;
    }
    _run(command);
  }

  /// The one place that decides what a command does, depending on context
  /// (list open or not, live TV or movie).
  void _run(String command) {
    final player = ref.read(playerProvider.notifier);
    final vod = ref.read(playerProvider).isVod;

    if (command.length == 2 && command.startsWith('d')) {
      _numeric.addDigit(int.parse(command.substring(1)));
      setState(() => _notice = null);
      return;
    }
    switch (command) {
      case 'up':
        _listOpen ? _moveHighlight(-1) : _step(-1);
      case 'down':
        _listOpen ? _moveHighlight(1) : _step(1);
      case 'pageup':
        _listOpen ? _moveHighlight(-10) : _step(-1);
      case 'pagedown':
        _listOpen ? _moveHighlight(10) : _step(1);
      case 'left':
        if (_listOpen) {
          _stepGroup(-1);
        } else if (vod) {
          player.seekBy(const Duration(seconds: -10));
        } else {
          player.changeVolume(-5);
        }
      case 'right':
        if (_listOpen) {
          _stepGroup(1);
        } else if (vod) {
          player.seekBy(const Duration(seconds: 30));
        } else {
          player.changeVolume(5);
        }
      case 'ok':
        if (_numeric.active) {
          _numeric.commit();
        } else if (_listOpen) {
          _playHighlighted();
        } else {
          _openList();
        }
      case 'back':
        if (_numeric.active) {
          _numeric.cancel();
          setState(() {});
        } else if (_listOpen) {
          _closeList();
        } else if (_fullscreen) {
          _setFullscreen(false);
        }
      case 'last':
        player.playPrevious();
      case 'fullscreen':
        _setFullscreen(!_fullscreen);
      case 'mute':
        player.toggleMute();
      case 'volup':
        player.changeVolume(5);
      case 'voldown':
        player.changeVolume(-5);
      case 'chup':
        _step(1);
      case 'chdown':
        _step(-1);
      case 'zoom':
        ref.read(settingsProvider.notifier).update(
            (s) => s.copyWith(zoom: ZoomMode.values[(s.zoom.index + 1) % ZoomMode.values.length]));
      case 'info':
        setState(() => _infoTick++);
      case 'playpause':
        vod ? player.togglePause() : (_listOpen ? _closeList() : _openList());
      case 'list':
        _listOpen ? _closeList() : _openList();
      case 'series':
        _openSeries();
    }
  }

  // ------------------------------------------------------------------ actions

  bool get _favoritesMode => ref.read(channelFilterProvider).mode == ListMode.favorites;

  /// Channel up/down within the current list (falls back to all channels).
  void _step(int delta) {
    final current = ref.read(playerProvider).channel;
    var list = ref.read(visibleChannelsProvider);
    if (current != null && !list.any((c) => c.id == current.id)) list = ref.read(allowedChannelsProvider);
    if (list.isEmpty) return;
    final idx = current == null ? -1 : list.indexWhere((c) => c.id == current.id);
    final next = idx < 0 ? (delta > 0 ? 0 : list.length - 1) : (idx + delta) % list.length;
    ref.read(playerProvider.notifier).play(list[next]);
  }

  void _tuneNumber(int number) {
    Channel? channel;
    if (ref.read(settingsProvider).favoriteNumbers) {
      final favorites = ref.read(favoritesProvider);
      if (number <= favorites.length) channel = ref.read(channelsByIdProvider)[favorites[number - 1]];
    } else {
      channel = channelByNumber(ref.read(allowedChannelsProvider), number);
    }
    if (channel == null) {
      _showNotice('No channel $number');
    } else {
      ref.read(playerProvider.notifier).play(channel);
    }
    setState(() {});
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _openList() {
    final list = ref.read(visibleChannelsProvider);
    final current = ref.read(playerProvider).channel;
    final idx = current == null ? 0 : list.indexWhere((c) => c.id == current.id);
    setState(() {
      _listOpen = true;
      _highlight = idx < 0 ? 0 : idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible(_highlight));
  }

  void _closeList() {
    _searchFocus.unfocus();
    _rootFocus.requestFocus();
    setState(() => _listOpen = false);
  }

  void _moveHighlight(int delta) {
    final len = ref.read(visibleChannelsProvider).length;
    if (len == 0) return;
    setState(() => _highlight = (_highlight + delta).clamp(0, len - 1));
    _ensureVisible(_highlight);
  }

  void _moveFavorite(int delta) {
    final list = ref.read(visibleChannelsProvider);
    if (_highlight >= list.length) return;
    ref.read(favoritesProvider.notifier).move(list[_highlight].id, delta);
    _moveHighlight(delta);
  }

  void _stepGroup(int delta) {
    final groups = <String?>[null, ...ref.read(groupsProvider)];
    final current = ref.read(channelFilterProvider).group;
    final idx = groups.indexOf(current);
    final next = groups[(idx + delta) % groups.length]; // Dart's % is never negative
    ref.read(channelFilterProvider.notifier).setGroup(next);
    setState(() => _highlight = 0);
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
  }

  void _playHighlighted() {
    final list = ref.read(visibleChannelsProvider);
    if (_highlight >= list.length) return;
    ref.read(playerProvider.notifier).play(list[_highlight]);
    if (_fullscreen) _closeList();
  }

  void _ensureVisible(int index) {
    if (!_listScroll.hasClients) return;
    final h = UiScale(_tv).tileHeight;
    final pos = _listScroll.position;
    final top = index * h;
    if (top < pos.pixels) {
      _listScroll.jumpTo(top);
    } else if (top + h > pos.pixels + pos.viewportDimension) {
      _listScroll.jumpTo((top + h - pos.viewportDimension).clamp(0, pos.maxScrollExtent));
    }
  }

  void _openSearch() {
    if (!_listOpen) _openList();
    _searchFocus.requestFocus();
    _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
  }

  void _leaveSearch() {
    _rootFocus.requestFocus();
    setState(() {
      _listOpen = true;
      _highlight = 0;
    });
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(channelFilterProvider.notifier).setQuery(text);
      setState(() => _highlight = 0);
    });
  }

  Future<void> _setFullscreen(bool value) async {
    if (!_isWindows) return;
    setState(() {
      _fullscreen = value;
      if (value) _listOpen = false;
    });
    await windowManager.setFullScreen(value);
  }

  Future<void> _openSettings() async {
    await openSettings(context, ref);
    if (mounted) _rootFocus.requestFocus();
  }

  Future<void> _openSeries() async {
    if (ref.read(xtreamApiProvider) == null) {
      _showNotice('Series need an Xtream login');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SeriesPage(onPlay: (ctx, media) {
        Navigator.of(ctx).popUntil((r) => r.isFirst);
        ref.read(playerProvider.notifier).play(media);
      }),
    ));
    if (mounted) _rootFocus.requestFocus();
  }

  /// Any input: show the cursor; hide it (and the fullscreen overlay) when idle.
  void _bumpIdle() {
    if (!_cursorVisible) setState(() => _cursorVisible = true);
    _idleTimer?.cancel();
    _idleTimer = Timer(cursorHideAfter, () {
      if (mounted && _fullscreen) setState(() => _cursorVisible = false);
    });
    _overlayTimer?.cancel();
    _overlayTimer = Timer(overlayHideAfter, () {
      if (mounted && _fullscreen && _listOpen && !_searchFocus.hasFocus) _closeList();
    });
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final tv = _isWindows && ref.watch(settingsProvider.select((s) => s.tvMode));
    final scale = UiScale(tv);
    final warning = ref.read(appPathsProvider).warning;
    if (_isWindows) ref.watch(remoteServerProvider); // keeps the phone remote running

    final player = PlayerView(
      scale: scale,
      numberBuffer: _numeric.buffer,
      notice: _notice,
      showHint: _isWindows,
      showControls: _cursorVisible,
      infoTick: _infoTick,
    );

    final panel = _ChannelPanel(
      scale: scale,
      listOpen: _listOpen,
      highlight: _highlight,
      scroll: _listScroll,
      search: _search,
      searchFocus: _searchFocus,
      onSearchChanged: _onSearchChanged,
      onSearchSubmitted: (_) => _leaveSearch(),
      onSelect: (c) {
        ref.read(playerProvider.notifier).play(c);
        if (_fullscreen) _closeList();
        _rootFocus.requestFocus();
      },
      onGroup: (g) {
        ref.read(channelFilterProvider.notifier).setGroup(g);
        setState(() => _highlight = 0);
        _rootFocus.requestFocus();
      },
      onSettings: _openSettings,
      onSeries: ref.watch(xtreamApiProvider) == null ? null : _openSeries,
      onFullscreen: _isWindows ? () => _setFullscreen(!_fullscreen) : null,
    );

    final body = _fullscreen
        ? Stack(
            fit: StackFit.expand,
            children: [
              player,
              if (_listOpen)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: scale.listWidth + scale.groupWidth,
                  child: ColoredBox(color: AppColors.background.withValues(alpha: 0.94), child: panel),
                ),
            ],
          )
        : Column(
            children: [
              PlaylistBanner(extraWarning: warning),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: scale.listWidth + scale.groupWidth, child: panel),
                    const VerticalDivider(width: 1),
                    Expanded(child: player),
                  ],
                ),
              ),
            ],
          );

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale.textScale)),
      child: Scaffold(
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: _cursorVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
            onHover: (_) => _bumpIdle(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: _isWindows ? () => _setFullscreen(!_fullscreen) : null,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelPanel extends ConsumerWidget {
  const _ChannelPanel({
    required this.scale,
    required this.listOpen,
    required this.highlight,
    required this.scroll,
    required this.search,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onSelect,
    required this.onGroup,
    required this.onSettings,
    required this.onSeries,
    required this.onFullscreen,
  });

  final UiScale scale;
  final bool listOpen;
  final int highlight;
  final ScrollController scroll;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<Channel> onSelect;
  final ValueChanged<String?> onGroup;
  final VoidCallback onSettings;
  final VoidCallback? onSeries;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(visibleChannelsProvider);
    final groups = ref.watch(groupsProvider);
    final filter = ref.watch(channelFilterProvider);
    final favoritesMode = filter.mode == ListMode.favorites;
    final favoriteNumbers = ref.watch(settingsProvider.select((s) => s.favoriteNumbers));
    final refreshing = ref.watch(playlistProvider.select((s) => s.refreshing));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
          child: Row(
            children: [
              const Text('AmarTv', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const Spacer(),
              ExcludeFocus(
                child: Row(children: [
                  if (onSeries != null)
                    IconButton(tooltip: 'Series (S)', onPressed: onSeries, icon: const Icon(Icons.video_library_outlined)),
                  IconButton(
                    tooltip: 'Refresh playlist',
                    onPressed: refreshing ? null : () => ref.read(playlistProvider.notifier).refresh(),
                    icon: refreshing
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                  if (onFullscreen != null)
                    IconButton(tooltip: 'Fullscreen (F)', onPressed: onFullscreen, icon: const Icon(Icons.fullscreen)),
                  IconButton(tooltip: 'Settings', onPressed: onSettings, icon: const Icon(Icons.settings)),
                ]),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: search,
            focusNode: searchFocus,
            onChanged: onSearchChanged,
            onSubmitted: onSearchSubmitted,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search (Ctrl+F)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: ExcludeFocus(child: ModeTabs()),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: scale.groupWidth,
                child: ExcludeFocus(
                  child: ListView.builder(
                    itemCount: groups.length + 1,
                    itemExtent: scale.tv ? 52 : 40,
                    itemBuilder: (context, i) {
                      final g = i == 0 ? null : groups[i - 1];
                      final selected = g == filter.group;
                      return Material(
                        color: selected ? AppColors.surfaceHigh : Colors.transparent,
                        child: InkWell(
                          onTap: () => onGroup(g),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                g == null ? 'All groups' : groupLabel(g),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected ? AppColors.text : AppColors.textDim,
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ChannelListView(
                  channels: channels,
                  scale: scale,
                  controller: scroll,
                  highlightIndex: listOpen ? highlight : null,
                  onSelect: onSelect,
                  reorderable: favoritesMode && filter.group == null && filter.query.isEmpty,
                  positionNumbers: favoritesMode && favoriteNumbers,
                ),
              ),
            ],
          ),
        ),
        if (listOpen)
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              favoritesMode
                  ? 'Up/Down: move   Shift+Up/Down: reorder   Enter: play   Esc: close'
                  : 'Up/Down: move   Left/Right: group   Enter: play   Esc: close',
              style: const TextStyle(color: AppColors.textDim, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
