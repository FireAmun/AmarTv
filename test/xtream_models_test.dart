import 'dart:convert';

import 'package:amartv/features/xtream/xtream_models.dart';
import 'package:flutter_test/flutter_test.dart';

String b64(String s) => base64.encode(utf8.encode(s));

void main() {
  test('account info', () {
    final a = AccountInfo.fromJson({
      'user_info': {'status': 'Active', 'exp_date': '1893456000', 'active_cons': '1', 'max_connections': '2', 'is_trial': '0'},
    })!;
    expect(a.isActive, isTrue);
    expect(a.expires, DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000));
    expect(a.activeConnections, 1);
    expect(a.maxConnections, 2);
    expect(AccountInfo.fromJson({'user_info': {'status': 'Expired', 'exp_date': null}})!.expires, isNull);
    expect(AccountInfo.fromJson('nope'), isNull);
  });

  test('short EPG with base64 titles and now/next', () {
    final programs = parseShortEpg({
      'epg_listings': [
        {'title': b64('Late Show'), 'start_timestamp': '2000', 'stop_timestamp': '3000'},
        {'title': b64('Match: Arsenal - Chelsea'), 'start_timestamp': '1000', 'stop_timestamp': '2000', 'description': b64('Live')},
        {'title': '', 'start_timestamp': '3000', 'stop_timestamp': '4000'}, // no title -> skipped
        {'title': 'Plain', 'start_timestamp': '5000', 'stop_timestamp': '4000'}, // ends before start -> skipped
      ],
    });
    expect(programs.map((p) => p.title), ['Match: Arsenal - Chelsea', 'Late Show']);
    expect(programs.first.description, 'Live');
    final nn = nowNextAt(programs, DateTime.fromMillisecondsSinceEpoch(1500 * 1000));
    expect(nn.now?.title, 'Match: Arsenal - Chelsea');
    expect(nn.next?.title, 'Late Show');
    expect(nn.now!.progressAt(DateTime.fromMillisecondsSinceEpoch(1500 * 1000)), closeTo(0.5, 0.001));
    expect(parseShortEpg('garbage'), isEmpty);
  });

  test('decodeMaybeBase64 keeps plain text', () {
    expect(decodeMaybeBase64(b64('Nachrichten')), 'Nachrichten');
    expect(decodeMaybeBase64('Hello World'), 'Hello World');
  });

  test('series episodes from a season map or a list', () {
    final fromMap = parseSeriesEpisodes({
      'episodes': {
        '2': [
          {'id': '22', 'season': 2, 'episode_num': 1, 'title': 'S2E1', 'container_extension': 'mkv'},
        ],
        '1': [
          {'id': '12', 'season': 1, 'episode_num': 2, 'title': 'S1E2', 'container_extension': 'mp4', 'info': {'duration_secs': 2700}},
          {'id': '11', 'season': 1, 'episode_num': 1, 'title': 'S1E1'},
          'garbage',
        ],
      },
    });
    expect(fromMap.map((e) => e.id), ['11', '12', '22']);
    expect(fromMap[1].duration, const Duration(minutes: 45));
    expect(fromMap[2].extension, 'mkv');

    final fromList = parseSeriesEpisodes({
      'episodes': [
        [
          {'id': '1', 'season': '1', 'episode_num': '1', 'title': 'A'},
        ],
      ],
    });
    expect(fromList.single.season, 1);
    expect(parseSeriesEpisodes(null), isEmpty);
  });

  test('series list and categories', () {
    final list = parseSeriesList([
      {'series_id': 5, 'name': 'Show', 'cover': 'http://c/5.jpg', 'category_id': '3', 'releaseDate': '2024'},
      {'series_id': null, 'name': 'Bad'},
      {'series_id': 6, 'name': ''},
    ]);
    expect(list.single.name, 'Show');
    expect(list.single.year, '2024');
    expect(parseCategories([{'category_id': 3, 'category_name': ' Drama '}]).single.name, 'Drama');
  });

  test('stream id from live urls', () {
    expect(streamIdFromUrl('http://h:80/live/u/p/12345.ts'), 12345);
    expect(streamIdFromUrl('http://h:80/u/p/678'), 678);
    expect(streamIdFromUrl('http://h/live/u/p/9.m3u8?token=1'), 9);
    expect(streamIdFromUrl('http://h/playlist.m3u8'), isNull);
  });
}
