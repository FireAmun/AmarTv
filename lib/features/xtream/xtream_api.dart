import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/providers.dart';
import '../playlist/xtream.dart';
import 'xtream_models.dart';

/// Small client for the Xtream `player_api.php` (account, EPG, series).
/// At most [_maxParallel] requests run at once so scrolling a long channel
/// list doesn't flood the provider.
class XtreamApi {
  XtreamApi(this.login, {String userAgent = ''})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          responseType: ResponseType.plain,
          headers: {if (userAgent.isNotEmpty) 'User-Agent': userAgent},
        ));

  static const _maxParallel = 3;

  final XtreamLogin login;
  final Dio _dio;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  void close() => _dio.close(force: true);

  Future<Object?> _get(String? action, [Map<String, String> extra = const {}]) async {
    if (_running >= _maxParallel) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    }
    _running++;
    try {
      final uri = login.api(action).replace(queryParameters: {
        ...login.api(action).queryParameters,
        ...extra,
      });
      final res = await _dio.getUri<String>(uri);
      return jsonDecode(res.data ?? 'null');
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  Future<AccountInfo?> account() async => AccountInfo.fromJson(await _get(null));

  Future<List<EpgProgram>> shortEpg(int streamId, {int limit = 4}) async =>
      parseShortEpg(await _get('get_short_epg', {'stream_id': '$streamId', 'limit': '$limit'}));

  Future<List<SeriesCategory>> seriesCategories() async => parseCategories(await _get('get_series_categories'));

  Future<List<SeriesItem>> seriesList() async => parseSeriesList(await _get('get_series'));

  Future<List<Episode>> seriesEpisodes(int seriesId) async =>
      parseSeriesEpisodes(await _get('get_series_info', {'series_id': '$seriesId'}));

  String episodeUrl(Episode e) => '${login.base}/series/${login.username}/${login.password}/${e.id}.${e.extension}';
}

/// null when the playlist URL has no Xtream login (plain M3U provider).
final xtreamApiProvider = Provider<XtreamApi?>((ref) {
  final config = ref.watch(configProvider);
  final login = XtreamLogin.fromPlaylistUrl(config.playlistUrl);
  if (login == null) return null;
  final api = XtreamApi(login, userAgent: config.userAgent);
  ref.onDispose(api.close);
  return api;
});

/// Subscription status; refreshed when the login changes or on demand.
final accountProvider = FutureProvider<AccountInfo?>((ref) async {
  final api = ref.watch(xtreamApiProvider);
  if (api == null) return null;
  try {
    final info = await api.account();
    if (info != null) {
      AppLog.i('Account: ${info.status}, expires ${info.expires ?? 'never'}, '
          'connections ${info.activeConnections}/${info.maxConnections}');
    }
    return info;
  } catch (e) {
    AppLog.w('Account info failed: $e');
    return null;
  }
});
