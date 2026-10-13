import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/backoff.dart';
import '../../core/log.dart';
import '../../core/providers.dart';
import '../../core/url_mask.dart';
import '../playlist/channel.dart';
import '../playlist/playlist_controller.dart';
import '../settings/app_settings.dart';
import '../vod/episode_media.dart';
import '../xtream/epg.dart';
import '../xtream/xtream_api.dart';
import 'stream_url.dart';

enum PlayerStatus { idle, connecting, buffering, playing, reconnecting, unavailable }

class PlayerUiState {
  const PlayerUiState({
    this.channel,
    this.status = PlayerStatus.idle,
    this.message,
    this.volume = 100,
    this.muted = false,
    this.audioTracks = const [],
    this.audioTrack,
    this.sleepAt,
    this.paused = false,
    this.resumedFrom,
    this.subtitleTracks = const [],
    this.subtitleTrack,
    this.liveLag,
    this.upNext,
  });

  final Channel? channel;

  /// Movies/episodes only (live TV is never paused).
  final bool paused;

  /// Set for a few seconds after a movie/episode jumped to where you stopped
  /// (shows "Continuing from ..." with a Start over button).
  final Duration? resumedFrom;

  final List<SubtitleTrack> subtitleTracks;
  final SubtitleTrack? subtitleTrack;

  /// Live only: how far playback is behind the live edge (null = unknown).
  final Duration? liveLag;

  /// The next episode, counting down after an episode finished.
  final Channel? upNext;

  bool get isVod => channel != null && isVodUrl(channel!.url);
  final PlayerStatus status;

  /// Extra status detail, e.g. "Retrying in 4 s" or an error. Already masked.
  final String? message;
  final double volume;
  final bool muted;
  final List<AudioTrack> audioTracks;
  final AudioTrack? audioTrack;
  final DateTime? sleepAt;

  PlayerUiState copyWith({
    Channel? channel,
    PlayerStatus? status,
    String? message,
    bool clearMessage = false,
    double? volume,
    bool? muted,
    List<AudioTrack>? audioTracks,
    AudioTrack? audioTrack,
    DateTime? sleepAt,
    bool clearSleep = false,
    bool? paused,
    Duration? resumedFrom,
    bool clearResumed = false,
    List<SubtitleTrack>? subtitleTracks,
    SubtitleTrack? subtitleTrack,
    Duration? liveLag,
    bool clearLiveLag = false,
    Channel? upNext,
    bool clearUpNext = false,
  }) =>
      PlayerUiState(
        subtitleTracks: subtitleTracks ?? this.subtitleTracks,
        subtitleTrack: subtitleTrack ?? this.subtitleTrack,
        liveLag: clearLiveLag ? null : (liveLag ?? this.liveLag),
        upNext: clearUpNext ? null : (upNext ?? this.upNext),
        resumedFrom: clearResumed ? null : (resumedFrom ?? this.resumedFrom),
        channel: channel ?? this.channel,
        status: status ?? this.status,
        message: clearMessage ? null : (message ?? this.message),
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        audioTracks: audioTracks ?? this.audioTracks,
        audioTrack: audioTrack ?? this.audioTrack,
        sleepAt: clearSleep ? null : (sleepAt ?? this.sleepAt),
        paused: paused ?? this.paused,
      );
}

/// One [Player] reused for every channel.
///
/// Every open gets a generation number; timers and async work started for an
/// older generation are ignored, so rapid Up/Down switching can't race.
class PlayerController extends Notifier<PlayerUiState> {
  static const stallTimeout = Duration(seconds: 10);
  static const connectTimeout = Duration(seconds: 25);
  static const stableAfter = Duration(seconds: 30);
  static const maxPermanentErrors = 3;
  static const maxFailuresBeforeFirstPlay = 6;

  late final Player player;
  late final VideoController video;

  final _subs = <StreamSubscription<dynamic>>[];
  final _backoff = Backoff();

  int _gen = 0;
  bool _active = false;
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _stableTimer;
  Timer? _sleepTimer;
  DateTime _openedAt = DateTime.now();
  DateTime _lastProgress = DateTime.now();
  Duration _lastPosition = Duration.zero;
  bool _playedThisChannel = false;
  int _permanentErrors = 0;
  int _failures = 0;
  Channel? _previousChannel;

  // Movies/episodes: resume point to apply once the duration is known.
  Duration? _pendingSeek;

  /// The pending seek comes from a saved position (show "Continuing from").
  bool _announceResume = false;
  Timer? _resumeNoticeTimer;
  bool _userPaused = false;
  Timer? _positionSaver;

  // Live delay: wall clock vs. played time since playback (re)started.
  static const liveJumpAfter = Duration(seconds: 20);
  static const liveCatchUpAbove = Duration(seconds: 3);
  DateTime? _liveBaseWall;
  Duration _liveBasePos = Duration.zero;
  DateTime _lastLiveJump = DateTime.fromMillisecondsSinceEpoch(0);
  double _rate = 1.0;

  /// The url actually opened (live channels may be switched to HLS).
  String _openedUrl = '';

  String? _subsAppliedFor;
  Timer? _upNextTimer;

  Channel? get previousChannel => _previousChannel;

  @override
  PlayerUiState build() {
    final settings = ref.read(settingsProvider);
    player = Player(
      configuration: PlayerConfiguration(
        title: 'AmarTv',
        bufferSize: _bufferBytes(settings.profile),
        // media_kit only forwards a few log lines to `stream.error` (not
        // e.g. "HTTP error 404"), so errors are read from the log instead.
        logLevel: MPVLogLevel.warn,
      ),
    );
    video = VideoController(
      player,
      configuration: VideoControllerConfiguration(hwdec: _hwdec(settings.profile)),
    );
    unawaited(_applyOptions(settings.profile));
    unawaited(player.setVolume(settings.muted ? 0 : settings.volume));

    _subs.addAll([
      player.stream.log.listen(_onLog),
      player.stream.completed.listen((done) {
        if (!done || !_active || _justOpened(const Duration(seconds: 1))) return;
        if (state.isVod) {
          _onVodFinished();
        } else {
          _fail(_gen, 'The stream ended.');
        }
      }),
      player.stream.duration.listen(_applyPendingSeek),
      player.stream.buffering.listen((_) => _updateStatus()),
      player.stream.playing.listen((_) => _updateStatus()),
      player.stream.position.listen(_onPosition),
      player.stream.tracks.listen((t) {
        final audio = t.audio.where((a) => a.id != 'auto' && a.id != 'no').toList();
        final subs = t.subtitle.where((a) => a.id != 'auto' && a.id != 'no').toList();
        state = state.copyWith(audioTracks: audio, subtitleTracks: subs);
        _applyPreferredSubtitle(subs);
      }),
      player.stream.track.listen((t) => state = state.copyWith(audioTrack: t.audio, subtitleTrack: t.subtitle)),
    ]);
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _checkStall());
    _positionSaver = Timer.periodic(const Duration(seconds: 10), (_) => _savePosition());

    ref.listen(settingsProvider.select((s) => s.profile), (_, profile) => _applyProfile(profile));
    ref.listen(settingsProvider.select((s) => s.liveFormat), (_, _) {
      final channel = state.channel;
      if (_active && channel != null && !state.isVod) play(channel);
    });
    ref.listen(configProvider.select((c) => c.userAgent), (_, ua) => _applyOptions(ref.read(settingsProvider).profile));

    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
      _retryTimer?.cancel();
      _watchdog?.cancel();
      _stableTimer?.cancel();
      _sleepTimer?.cancel();
      _positionSaver?.cancel();
      _resumeNoticeTimer?.cancel();
      _upNextTimer?.cancel();
      WakelockPlus.disable();
      player.dispose();
    });

    return PlayerUiState(volume: settings.volume, muted: settings.muted);
  }

  // ---------------------------------------------------------------- options

  static String _hwdec(PlaybackProfile p) => p == PlaybackProfile.auto ? 'auto-safe' : 'no';
  static int _bufferBytes(PlaybackProfile p) =>
      p == PlaybackProfile.auto ? 32 * 1024 * 1024 : 12 * 1024 * 1024;

  NativePlayer? get _native => player.platform is NativePlayer ? player.platform as NativePlayer : null;

  /// mpv options (names checked against media_kit 1.2.6 / libmpv docs).
  Future<void> _applyOptions(PlaybackProfile profile) async {
    final native = _native;
    if (native == null) return;
    final ua = ref.read(configProvider).userAgent;
    final compat = profile == PlaybackProfile.compatibility;
    final options = <String, String>{
      // media_kit enables a disk cache by default: keep it in RAM instead
      // (portable USB folder, no writes to temp).
      'cache-on-disk': 'no',
      'network-timeout': '15',
      'demuxer-max-bytes': '${_bufferBytes(profile)}',
      'demuxer-max-back-bytes': compat ? '${2 * 1024 * 1024}' : '${8 * 1024 * 1024}',
      'demuxer-readahead-secs': compat ? '5' : '10',
      'cache-secs': compat ? '10' : '20',
      'hwdec': _hwdec(profile),
      // Cheaper software decoding on old CPUs.
      'vd-lavc-fast': compat ? 'yes' : 'no',
      'vd-lavc-skiploopfilter': compat ? 'nonkey' : 'default',
      if (ua.isNotEmpty) 'user-agent': ua,
    };
    for (final e in options.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (err) {
        AppLog.w('mpv option ${e.key} rejected: $err');
      }
    }
  }

  Future<void> _applyProfile(PlaybackProfile profile) async {
    AppLog.i('Playback profile: ${profile.name}');
    await _applyOptions(profile);
    final channel = state.channel;
    if (_active && channel != null) await play(channel); // reopen with new decoder
  }

  // ---------------------------------------------------------------- playback

  Future<void> play(Channel channel) async {
    await _savePosition();
    _upNextTimer?.cancel();
    final gen = ++_gen;
    _retryTimer?.cancel();
    _stableTimer?.cancel();
    _backoff.reset();
    _permanentErrors = 0;
    _failures = 0;
    _playedThisChannel = false;
    _active = true;
    _userPaused = false;
    _pendingSeek = null;
    _announceResume = false;
    if (isVodUrl(channel.url)) {
      final saved = await ref.read(databaseProvider).loadPosition(channel.id);
      if (gen != _gen) return;
      if (saved != null && saved > const Duration(seconds: 30)) {
        _pendingSeek = saved;
        _announceResume = true;
      }
    }

    final current = state.channel;
    if (current != null && current.id != channel.id) _previousChannel = current;

    _resumeNoticeTimer?.cancel();
    state = state.copyWith(
        channel: channel,
        status: PlayerStatus.connecting,
        clearMessage: true,
        paused: false,
        clearResumed: true,
        clearLiveLag: true,
        clearUpNext: true);
    unawaited(ref.read(historyProvider.notifier).add(channel.id));
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(lastChannelId: channel.id));
    unawaited(WakelockPlus.enable().catchError((_) {}));
    AppLog.i('Play #${channel.number} ${channel.name}');
    await _open(gen);
  }

  Future<void> _open(int gen) async {
    final channel = state.channel;
    if (channel == null || gen != _gen || !_active) return;
    _openedAt = DateTime.now();
    _lastProgress = _openedAt;
    _lastPosition = Duration.zero;
    _liveBaseWall = null;
    final vod = isVodUrl(channel.url);
    _openedUrl = vod ? channel.url : liveStreamUrl(channel.url, ref.read(settingsProvider).liveFormat);
    await _applyBuffer(vod: vod);
    if (_rate != 1.0) await _setRate(1.0);
    try {
      await player.open(Media(_openedUrl), play: true);
    } catch (e) {
      _fail(gen, e.toString());
    }
  }

  /// Live: small buffer so playback can't drift far behind. Movies: big buffer.
  Future<void> _applyBuffer({required bool vod}) async {
    final native = _native;
    if (native == null) return;
    final compat = ref.read(settingsProvider).profile == PlaybackProfile.compatibility;
    final options = vod
        ? {'cache-secs': '60', 'demuxer-readahead-secs': compat ? '20' : '60'}
        : {'cache-secs': compat ? '12' : '8', 'demuxer-readahead-secs': compat ? '8' : '5'};
    for (final e in options.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {}
    }
  }

  Future<void> _setRate(double rate) async {
    _rate = rate;
    try {
      await player.setRate(rate);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- live delay

  /// Called every 2 s. Measures how far live playback is behind and keeps it
  /// close: play 5% faster while catching up on what is already downloaded,
  /// or reconnect ("jump to live") when far behind (auto mode).
  void _liveSyncTick() {
    final s = player.state;
    if (!_active || state.isVod || !_playedThisChannel || (_retryTimer?.isActive ?? false)) return;
    final base = _liveBaseWall;
    if (base == null) return;
    final now = DateTime.now();
    var lag = now.difference(base) - (s.position - _liveBasePos);
    if (lag.isNegative) {
      // Played faster than real time from a full buffer: re-anchor.
      _liveBaseWall = now;
      _liveBasePos = s.position;
      lag = Duration.zero;
    }
    if ((lag - (state.liveLag ?? Duration.zero)).abs() >= const Duration(seconds: 1) || state.liveLag == null) {
      state = state.copyWith(liveLag: lag);
    }

    final auto = ref.read(settingsProvider).liveSync == LiveSync.auto;
    if (auto && lag > liveJumpAfter && !s.buffering && now.difference(_lastLiveJump) > const Duration(seconds: 60)) {
      AppLog.i('Live delay ${lag.inSeconds} s - jumping to live');
      jumpToLive();
      return;
    }
    final ahead = s.buffer - s.position;
    final wantRate = auto && lag > liveCatchUpAbove && ahead > const Duration(seconds: 2) ? 1.05 : 1.0;
    if (wantRate != _rate && !s.buffering) _setRate(wantRate);
  }

  /// Reconnects the live channel: a new connection starts at the live edge.
  void jumpToLive() {
    if (!_active || state.isVod || state.channel == null) return;
    _lastLiveJump = DateTime.now();
    _playedThisChannel = false;
    state = state.copyWith(liveLag: Duration.zero);
    _open(_gen);
  }

  /// Stops playback and all retries (leaving the player, backgrounded).
  Future<void> stop({String? message}) async {
    await _savePosition();
    _upNextTimer?.cancel();
    if (state.upNext != null) state = state.copyWith(clearUpNext: true);
    _gen++;
    _active = false;
    _retryTimer?.cancel();
    _stableTimer?.cancel();
    state = state.copyWith(status: PlayerStatus.idle, message: message, clearMessage: message == null);
    unawaited(WakelockPlus.disable().catchError((_) {}));
    await player.stop();
  }

  Future<void> retry() async {
    final channel = state.channel;
    if (channel != null) await play(channel);
  }

  Future<void> playPrevious() async {
    final prev = _previousChannel;
    if (prev != null) await play(prev);
  }

  // ---------------------------------------------------------------- health

  void _onPosition(Duration pos) {
    if (pos == _lastPosition) return;
    _lastPosition = pos;
    _lastProgress = DateTime.now();
    if (_active && !state.isVod && _liveBaseWall == null && player.state.playing && !player.state.buffering) {
      _liveBaseWall = DateTime.now();
      _liveBasePos = pos;
    }
    if (_active && !_playedThisChannel && player.state.playing) {
      _playedThisChannel = true;
      final gen = _gen;
      // Reset the backoff only after playback has been stable for a while.
      _stableTimer?.cancel();
      _stableTimer = Timer(stableAfter, () {
        if (gen == _gen) {
          _backoff.reset();
          _permanentErrors = 0;
          _failures = 0;
        }
      });
    }
    _updateStatus();
  }

  void _updateStatus() {
    if (!_active) return;
    final s = player.state;
    final PlayerStatus next;
    if (_retryTimer?.isActive ?? false) {
      next = PlayerStatus.reconnecting;
    } else if (_userPaused && _playedThisChannel) {
      next = PlayerStatus.playing;
    } else if (s.buffering) {
      next = _playedThisChannel ? PlayerStatus.buffering : PlayerStatus.connecting;
    } else if (s.playing && _playedThisChannel) {
      next = PlayerStatus.playing;
    } else {
      next = state.status == PlayerStatus.reconnecting ? PlayerStatus.reconnecting : PlayerStatus.connecting;
    }
    if (next != state.status) {
      state = state.copyWith(status: next, clearMessage: next == PlayerStatus.playing);
    }
  }

  void _checkStall() {
    _liveSyncTick();
    if (!_active || _userPaused || (_retryTimer?.isActive ?? false)) return;
    final now = DateTime.now();
    final s = player.state;
    if (_playedThisChannel && s.playing && !s.buffering && now.difference(_lastProgress) > stallTimeout) {
      _fail(_gen, 'No video for ${stallTimeout.inSeconds} s (stalled).');
    } else if (now.difference(_lastProgress) > connectTimeout) {
      // Stuck connecting/buffering with no progress at all.
      _fail(_gen, 'No data for ${connectTimeout.inSeconds} s.');
    }
  }

  void _onLog(PlayerLog log) {
    if (!_active) return;
    final level = log.level;
    final isError = level == 'error' || level == 'fatal';
    final isHttpWarning = level == 'warn' && log.text.contains(RegExp(r'HTTP error|Server returned', caseSensitive: false));
    if (!isError && !isHttpWarning) return;
    final text = '${log.prefix}: ${log.text}';
    // An error naming another url belongs to the previous channel.
    final url = _urls.firstMatch(log.text)?.group(0);
    if (url != null && url.replaceAll(RegExp(r'[.,;]+$'), '') != _openedUrl) return;
    // Only react to errors that stop playback; mpv also reports recoverable ones.
    if (_isFatal(text)) {
      _fail(_gen, text);
    } else {
      AppLog.i('mpv $level $text');
    }
  }

  bool _justOpened(Duration window) => DateTime.now().difference(_openedAt) < window;

  static final _httpCode = RegExp(r'\b(4\d\d|5\d\d)\b');

  /// URLs are removed before looking for HTTP codes: a stream id like
  /// `/403.ts` must not look like "403 Forbidden".
  static final _urls = RegExp(r'[a-z][a-z0-9+.-]*://\S+', caseSensitive: false);

  static bool _isFatal(String text) {
    final t = text.toLowerCase().replaceAll(_urls, '');
    return _httpCode.hasMatch(t) ||
        t.contains('failed to open') ||
        t.contains('failed to recognize') ||
        t.contains('connection refused') ||
        t.contains('timed out') ||
        t.contains('could not open') ||
        t.contains('no such file');
  }

  /// 401/403/404/410 are usually permanent. Providers that allow a single
  /// connection can briefly answer 403 while the previous stream is still
  /// counted, so give up only after a few in a row.
  static int? permanentCode(String text) {
    final m = RegExp(r'\b(401|403|404|410)\b').firstMatch(text.replaceAll(_urls, ''));
    return m == null ? null : int.parse(m[1]!);
  }

  void _fail(int gen, String reason) {
    if (gen != _gen || !_active || (_retryTimer?.isActive ?? false)) return;
    _stableTimer?.cancel();
    _failures++;
    final masked = maskUrl(reason);
    AppLog.w('Playback problem (#${state.channel?.number}): $masked');

    final code = permanentCode(reason);
    if (code != null) {
      _permanentErrors++;
      if (_permanentErrors >= maxPermanentErrors) {
        _giveUp(switch (code) {
          401 || 403 => 'Access denied by the provider (HTTP $code). '
              'Check your subscription, or close other devices using it.',
          _ => 'This channel is not available (HTTP $code).',
        });
        return;
      }
    }
    if (!_playedThisChannel && _failures >= maxFailuresBeforeFirstPlay) {
      _giveUp('The stream could not be started.');
      return;
    }

    final delay = _backoff.next();
    if (state.isVod && _lastPosition > const Duration(seconds: 5)) _pendingSeek = _lastPosition;
    _playedThisChannel = false;
    state = state.copyWith(
      status: PlayerStatus.reconnecting,
      message: 'Retrying in ${(delay.inMilliseconds / 1000).ceil()} s (attempt ${_backoff.attempt})',
    );
    _retryTimer = Timer(delay, () {
      if (gen != _gen || !_active) return;
      _retryTimer = null;
      state = state.copyWith(status: PlayerStatus.reconnecting, message: 'Reconnecting...');
      _open(gen);
    });
  }

  void _giveUp(String message) {
    _gen++;
    _active = false;
    _retryTimer?.cancel();
    state = state.copyWith(status: PlayerStatus.unavailable, message: message);
    unawaited(WakelockPlus.disable().catchError((_) {}));
    unawaited(player.stop());
  }

  // ---------------------------------------------------------------- controls

  void setVolume(double volume) {
    final v = volume.clamp(0, 100).toDouble();
    state = state.copyWith(volume: v, muted: false);
    player.setVolume(v);
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(volume: v, muted: false));
  }

  void changeVolume(double delta) => setVolume(state.volume + delta);

  void toggleMute() {
    final muted = !state.muted;
    state = state.copyWith(muted: muted);
    player.setVolume(muted ? 0 : state.volume);
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(muted: muted));
  }

  Future<void> setAudioTrack(AudioTrack track) => player.setAudioTrack(track);

  // ---------------------------------------------------------------- movies / episodes

  void togglePause() {
    if (!state.isVod || !_active) return;
    _userPaused = !_userPaused;
    _userPaused ? player.pause() : player.play();
    _lastProgress = DateTime.now();
    state = state.copyWith(paused: _userPaused);
    if (_userPaused) _savePosition();
  }

  void seekBy(Duration delta) {
    if (!state.isVod || !_active) return;
    final duration = player.state.duration;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration - const Duration(seconds: 2)) {
      target = duration - const Duration(seconds: 2);
    }
    _lastProgress = DateTime.now();
    player.seek(target);
  }

  void _applyPendingSeek(Duration duration) {
    final target = _pendingSeek;
    if (target == null || duration <= Duration.zero) return;
    _pendingSeek = null;
    final announce = _announceResume;
    _announceResume = false;
    if (target < duration - const Duration(seconds: 60)) {
      AppLog.i('Resuming at ${target.inSeconds} s');
      player.seek(target);
      // Only a resume from "where you stopped" is announced, not a reconnect.
      if (announce) {
        state = state.copyWith(resumedFrom: target);
        _resumeNoticeTimer?.cancel();
        _resumeNoticeTimer = Timer(const Duration(seconds: 8), () => state = state.copyWith(clearResumed: true));
      }
    }
  }

  /// "Start over": play the current movie/episode from the beginning.
  void restart() {
    final channel = state.channel;
    if (channel == null || !state.isVod || !_active) return;
    _resumeNoticeTimer?.cancel();
    _lastProgress = DateTime.now();
    player.seek(Duration.zero);
    ref.read(databaseProvider).deletePosition(channel.id);
    state = state.copyWith(clearResumed: true);
  }

  Future<void> _savePosition() async {
    final channel = state.channel;
    if (channel == null || !state.isVod || !_active) return;
    final pos = player.state.position;
    final dur = player.state.duration;
    if (pos < const Duration(seconds: 30) || dur <= Duration.zero) return;
    final db = ref.read(databaseProvider);
    try {
      if (pos > dur - const Duration(seconds: 60)) {
        await db.markWatched(channel, dur);
      } else {
        await db.savePosition(channel, pos, dur);
      }
    } catch (e) {
      AppLog.w('Saving resume position failed: $e');
    }
  }

  void _onVodFinished() {
    final channel = state.channel;
    if (channel != null) ref.read(databaseProvider).markWatched(channel, player.state.duration);
    _gen++;
    _active = false;
    _retryTimer?.cancel();
    state = state.copyWith(status: PlayerStatus.idle, message: 'Finished.', paused: false);
    unawaited(WakelockPlus.disable().catchError((_) {}));
    if (channel != null) unawaited(_queueNextEpisode(channel));
  }

  static const upNextDelay = Duration(seconds: 10);

  /// After an episode: show "Next episode" and play it after [upNextDelay].
  Future<void> _queueNextEpisode(Channel finished) async {
    final seriesId = seriesIdOf(finished);
    final episodeId = episodeIdOf(finished);
    final api = ref.read(xtreamApiProvider);
    if (seriesId == null || episodeId == null || api == null) return;
    try {
      final next = nextEpisode(await api.seriesEpisodes(seriesId), episodeId);
      if (next == null || state.channel?.id != finished.id || _active) return;
      final media = episodeMedia(api,
          seriesId: seriesId, seriesName: seriesNameOf(finished), cover: finished.logo, e: next);
      state = state.copyWith(upNext: media, clearMessage: true);
      _upNextTimer?.cancel();
      _upNextTimer = Timer(upNextDelay, playUpNext);
    } catch (e) {
      AppLog.w('Next episode lookup failed: $e');
    }
  }

  void playUpNext() {
    final next = state.upNext;
    _upNextTimer?.cancel();
    if (next != null) play(next);
  }

  void cancelUpNext() {
    _upNextTimer?.cancel();
    state = state.copyWith(clearUpNext: true);
  }

  // ---------------------------------------------------------------- subtitles

  /// Picks a subtitle track and remembers the language for the next movie.
  Future<void> setSubtitle(SubtitleTrack? track) async {
    await player.setSubtitleTrack(track ?? SubtitleTrack.no());
    final pref = track == null ? 'off' : (track.language ?? track.title ?? '').trim();
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(subtitleLanguage: pref));
  }

  /// Applies the remembered subtitle choice once per movie/episode.
  void _applyPreferredSubtitle(List<SubtitleTrack> subs) {
    final channel = state.channel;
    if (channel == null || !state.isVod || subs.isEmpty || _subsAppliedFor == channel.id) return;
    _subsAppliedFor = channel.id;
    final pref = ref.read(settingsProvider).subtitleLanguage.toLowerCase();
    if (pref.isEmpty) return; // leave the file's default
    if (pref == 'off') {
      player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    for (final t in subs) {
      final label = '${t.language ?? ''} ${t.title ?? ''}'.toLowerCase();
      if (label.contains(pref)) {
        player.setSubtitleTrack(t);
        return;
      }
    }
  }

  /// null cancels the sleep timer.
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    if (duration == null) {
      state = state.copyWith(clearSleep: true);
      return;
    }
    final at = DateTime.now().add(duration);
    state = state.copyWith(sleepAt: at);
    _sleepTimer = Timer(duration, () {
      state = state.copyWith(clearSleep: true);
      stop(message: 'Sleep timer: playback stopped.');
    });
  }

  /// Android: release playback in the background, resume on return.
  bool _suspended = false;

  Future<void> suspend() async {
    if (!_active) return;
    _suspended = true;
    await stop();
  }

  Future<void> resume() async {
    if (!_suspended) return;
    _suspended = false;
    final channel = state.channel;
    if (channel != null) await play(channel);
  }
}

final playerProvider = NotifierProvider<PlayerController, PlayerUiState>(PlayerController.new);
