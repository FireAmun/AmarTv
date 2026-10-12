import 'package:amartv/features/playlist/xtream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const login = XtreamLogin(base: 'http://host:8080', username: 'USER', password: 'PASS');

  test('login is read from a get.php url', () {
    final l = XtreamLogin.fromPlaylistUrl('http://host:8080/get.php?username=USER&password=PASS&type=m3u&output=ts')!;
    expect(l.base, 'http://host:8080');
    expect(l.username, 'USER');
    expect(l.password, 'PASS');
    expect(l.api('get_live_streams').toString(),
        'http://host:8080/player_api.php?username=USER&password=PASS&action=get_live_streams');
    expect(XtreamLogin.fromPlaylistUrl('http://host/list.m3u'), isNull);
  });

  test('live streams become channels with groups, logos and numbers', () {
    final r = parseXtream(const XtreamPayload(
      login: login,
      liveCategories: '[{"category_id":"1","category_name":"Sports"},{"category_id":"2","category_name":"News"}]',
      liveStreams: '['
          '{"num":1,"name":"beIN Sports 1","stream_id":101,"stream_icon":"http://l/b1.png","epg_channel_id":"bein1","category_id":"1"},'
          '{"num":2,"name":"News 24","stream_id":"202","category_id":"2"},'
          '{"num":3,"name":"","stream_id":303,"category_id":"2"},'
          '{"name":"No id"},'
          '"garbage"'
          ']',
    ));
    expect(r.channels.map((c) => c.name), ['beIN Sports 1', 'News 24']);
    expect(r.skipped, 3);
    final c = r.channels.first;
    expect(c.url, 'http://host:8080/live/USER/PASS/101.ts');
    expect(c.group, 'Sports');
    expect(c.logo, 'http://l/b1.png');
    expect(c.tvgId, 'bein1');
    expect(c.number, 1);
  });

  test('vod is added with its own groups only when given', () {
    final r = parseXtream(const XtreamPayload(
      login: login,
      liveCategories: '[]',
      liveStreams: '[{"num":1,"name":"Live","stream_id":1,"category_id":"9"}]',
      vodCategories: '[{"category_id":"5","category_name":"Action"}]',
      vodStreams: '[{"name":"Film","stream_id":7,"category_id":"5","container_extension":"mkv"}]',
    ));
    expect(r.channels.last.url, 'http://host:8080/movie/USER/PASS/7.mkv');
    expect(r.channels.last.group, 'Movies: Action');
  });

  test('invalid json gives an empty result instead of throwing', () {
    final r = parseXtream(const XtreamPayload(login: login, liveCategories: '<html>', liveStreams: 'nope'));
    expect(r.channels, isEmpty);
  });
}
