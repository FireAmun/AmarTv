import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/log.dart';
import '../../core/providers.dart';
import '../../core/url_mask.dart';
import 'channel.dart';
import 'm3u_parser.dart';
import 'xtream.dart';

class PlaylistState {
  const PlaylistState({
    this.channels = const [],
    this.loadingCache = true,
    this.refreshing = false,
    this.offline = false,
    this.error,
  });

  final List<Channel> channels;
  final bool loadingCache;
  final bool refreshing;

  /// Last refresh failed for network reasons; retrying every 30 s.
  final bool offline;

  /// Last refresh failed for another reason (HTTP error, empty playlist...).
  final String? error;

  PlaylistState copyWith({
    List<Channel>? channels,
    bool? loadingCache,
    bool? refreshing,
    bool? offline,
    String? error,
    bool clearError = false,
  }) =>
      PlaylistState(
        channels: channels ?? this.channels,
        loadingCache: loadingCache ?? this.loadingCache,
        refreshing: refreshing ?? this.refreshing,
        offline: offline ?? this.offline,
        error: clearError ? null : (error ?? this.error),
      );
}

class PlaylistController extends Notifier<PlaylistState> {
  static const autoRefreshEvery = Duration(hours: 24);
  static const offlineRetryEvery = Duration(seconds: 30);

  Timer? _offlineRetry;
  Timer? _autoRefresh;
  int _refreshGen = 0;

  @override
  PlaylistState build() {
    ref.onDispose(() {
      _offlineRetry?.cancel();
      _autoRefresh?.cancel();
    });
    // Refresh when the playlist URL / user agent changes in Settings.
    ref.listen(configProvider, (prev, next) {
      if (prev?.playlistUrl != next.playlistUrl || prev?.userAgent != next.userAgent) {
        refresh();
      }
    });
    ref.listen(settingsProvider.select((s) => s.includeVod), (_, _) => refresh());
    Future.microtask(_init);
    return const PlaylistState();
  }

  Future<void> _init() async {
    try {
      final cached = await ref.read(databaseProvider).loadChannels();
      state = state.copyWith(channels: cached, loadingCache: false);
      AppLog.i('Loaded ${cached.length} channels from cache');
    } catch (e) {
      AppLog.e('Loading cached channels failed: $e');
      state = state.copyWith(loadingCache: false);
    }
    // Check hourly whether the 24 h auto-refresh is due (survives sleep).
    _autoRefresh = Timer.periodic(const Duration(hours: 1), (_) {
      final last = ref.read(settingsProvider).lastRefresh;
      if (last == null || DateTime.now().difference(last) >= autoRefreshEvery) refresh();
    });
    await refresh();
  }

  /// Downloads and parses the playlist. The cached channels are only replaced
  /// after the new playlist parsed successfully.
  Future<void> refresh() async {
    final config = ref.read(configProvider);
    _offlineRetry?.cancel();
    if (!config.isConfigured) {
      state = state.copyWith(
        refreshing: false,
        offline: false,
        error: 'No playlist URL yet. Add it in Settings.',
      );
      return;
    }
    final gen = ++_refreshGen;
    state = state.copyWith(refreshing: true);
    try {
      final result = await _load(config, includeVod: ref.read(settingsProvider).includeVod);
      if (gen != _refreshGen) return;
      await ref.read(databaseProvider).replaceChannels(result.channels);
      if (gen != _refreshGen) return;
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(lastRefresh: DateTime.now()));
      state = state.copyWith(
        channels: result.channels,
        refreshing: false,
        offline: false,
        clearError: true,
      );
      AppLog.i('Playlist refreshed: ${result.channels.length} channels, ${result.skipped} skipped');
    } on _PlaylistError catch (e) {
      if (gen != _refreshGen) return;
      AppLog.w('Playlist refresh failed: ${e.message}');
      state = state.copyWith(refreshing: false, offline: false, error: e.message);
    } catch (e) {
      if (gen != _refreshGen) return;
      AppLog.w('Playlist refresh failed (network): $e');
      state = state.copyWith(refreshing: false, offline: true, clearError: true);
      _offlineRetry = Timer(offlineRetryEvery, refresh);
    }
  }

  /// Tries the M3U url first; if it is refused or not a playlist and the url
  /// carries username/password, falls back to the Xtream `player_api.php`.
  /// Network errors are rethrown (-> offline mode).
  Future<ParseResult> _load(AppConfig config, {required bool includeVod}) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 3),
      responseType: ResponseType.bytes,
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (_) => true,
      headers: {if (config.userAgent.isNotEmpty) 'User-Agent': config.userAgent},
    ));
    try {
      _PlaylistError m3uError;
      try {
        final text = await _get(dio, Uri.parse(config.playlistUrl.trim()));
        final result = await parseM3uInIsolate(text, excludeVod: !includeVod);
        if (result.channels.isNotEmpty) return result;
        m3uError = const _PlaylistError('The playlist is empty or not an M3U file.');
      } on _PlaylistError catch (e) {
        m3uError = e;
      }

      final login = XtreamLogin.fromPlaylistUrl(config.playlistUrl);
      if (login == null) throw m3uError;
      AppLog.i('M3U failed (${m3uError.message}) - trying the Xtream API');
      try {
        final info = jsonDecodeOrNull(await _get(dio, login.api(null)));
        final userInfo = info is Map ? info['user_info'] : null;
        final auth = userInfo is Map ? userInfo['auth'] : null;
        if (auth == null) throw const _PlaylistError('The server has no Xtream API.');
        if ('$auth' != '1') throw const _PlaylistError('Login refused - check username/password.');
        final payload = XtreamPayload(
          login: login,
          liveCategories: await _get(dio, login.api('get_live_categories')),
          liveStreams: await _get(dio, login.api('get_live_streams')),
          vodCategories: includeVod ? await _get(dio, login.api('get_vod_categories')) : null,
          vodStreams: includeVod ? await _get(dio, login.api('get_vod_streams')) : null,
        );
        final result = await parseXtreamInIsolate(payload);
        if (result.channels.isEmpty) throw const _PlaylistError('The account has no live channels.');
        AppLog.i('Loaded the channel list through the Xtream API');
        return result;
      } on _PlaylistError catch (e) {
        throw _PlaylistError('${m3uError.message}\nXtream API: ${e.message}');
      }
    } finally {
      dio.close();
    }
  }

  Future<String> _get(Dio dio, Uri uri) async {
    try {
      final res = await dio.getUri<List<int>>(uri);
      final code = res.statusCode ?? 0;
      if (code < 200 || code >= 300) throw _PlaylistError(_httpMessage(code));
      return decodePlaylist(res.data ?? const []);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.badCertificate) {
        throw const _PlaylistError('The playlist server has an invalid certificate.');
      }
      rethrow; // timeouts, connection errors -> treated as offline
    }
  }

  static String _httpMessage(int code) => switch (code) {
        401 || 403 => 'The provider refused access (HTTP $code). '
            'Check username/password, subscription, or try a User-Agent in config.json.',
        404 => 'Playlist not found (HTTP 404). Check the playlist URL, '
            'or try a User-Agent in config.json.',
        _ => 'The playlist server answered HTTP $code.',
      };

  Future<void> clearCache() async {
    await ref.read(databaseProvider).clearChannels();
    state = state.copyWith(channels: const []);
    AppLog.i('Playlist cache cleared');
  }
}

Object? jsonDecodeOrNull(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

class _PlaylistError implements Exception {
  const _PlaylistError(this.message);
  final String message;
  @override
  String toString() => maskUrl(message);
}

final playlistProvider = NotifierProvider<PlaylistController, PlaylistState>(PlaylistController.new);

/// All channels by id.
final channelsByIdProvider = Provider<Map<String, Channel>>((ref) {
  final list = ref.watch(playlistProvider.select((s) => s.channels));
  return {for (final c in list) c.id: c};
});

/// Favorite channel ids in the user's order (position = quick number).
class FavoritesController extends Notifier<List<String>> {
  @override
  List<String> build() {
    Future.microtask(() async {
      state = await ref.read(databaseProvider).loadFavorites();
    });
    return const [];
  }

  bool isFavorite(String id) => state.contains(id);

  Future<void> toggle(String id) async {
    final fav = !state.contains(id);
    state = fav ? [...state, id] : state.where((e) => e != id).toList();
    await ref.read(databaseProvider).setFavorite(id, fav);
  }

  /// Moves [id] by [delta] places (keyboard Shift+Up/Down).
  Future<void> move(String id, int delta) async {
    final i = state.indexOf(id);
    if (i < 0) return;
    await reorder(i, (i + delta).clamp(0, state.length - 1));
  }

  Future<void> reorder(int from, int to) async {
    if (from == to || from < 0 || from >= state.length) return;
    final list = [...state];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    state = list;
    await ref.read(databaseProvider).saveFavoriteOrder(list);
  }
}

final favoritesProvider = NotifierProvider<FavoritesController, List<String>>(FavoritesController.new);

class HistoryController extends Notifier<List<String>> {
  @override
  List<String> build() {
    Future.microtask(() async {
      state = await ref.read(databaseProvider).loadHistory();
    });
    return const [];
  }

  Future<void> add(String id) async {
    state = [id, ...state.where((e) => e != id)].take(50).toList();
    await ref.read(databaseProvider).addHistory(id);
  }
}

final historyProvider = NotifierProvider<HistoryController, List<String>>(HistoryController.new);
