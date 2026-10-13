import 'package:amartv/features/player/stream_url.dart';
import 'package:amartv/features/playlist/channel.dart';
import 'package:amartv/features/settings/app_settings.dart';
import 'package:amartv/features/vod/episode_media.dart';
import 'package:amartv/features/xtream/xtream_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('liveStreamUrl', () {
    test('switches Xtream live urls between TS and HLS', () {
      expect(liveStreamUrl('http://h:80/live/U/P/123.ts', LiveFormat.hls), 'http://h:80/live/U/P/123.m3u8');
      expect(liveStreamUrl('http://h:80/live/U/P/123.m3u8', LiveFormat.ts), 'http://h:80/live/U/P/123.ts');
      expect(liveStreamUrl('http://h:80/U/P/123', LiveFormat.hls), 'http://h:80/live/U/P/123.m3u8');
      expect(liveStreamUrl('http://h:80/live/U/P/123.ts', LiveFormat.ts), 'http://h:80/live/U/P/123.ts');
    });

    test('leaves other urls alone', () {
      expect(liveStreamUrl('https://cdn.example.com/stream/index.m3u8', LiveFormat.hls),
          'https://cdn.example.com/stream/index.m3u8');
      expect(liveStreamUrl('http://h/movie/U/P/7.mkv', LiveFormat.hls), 'http://h/movie/U/P/7.mkv');
      expect(liveStreamUrl('http://h/series/U/P/7.mp4', LiveFormat.hls), 'http://h/series/U/P/7.mp4');
    });
  });

  group('episodes', () {
    const ep = Channel(
      id: 'x',
      name: 'Breaking Bad - S1E04  Cancer Man',
      url: 'http://h:80/series/U/P/5512.mkv',
      tvgId: 'series:77',
    );

    test('series id, name and episode id are recovered from the media', () {
      expect(seriesIdOf(ep), 77);
      expect(seriesNameOf(ep), 'Breaking Bad');
      expect(episodeIdOf(ep), '5512');
      expect(seriesIdOf(const Channel(id: 'm', name: 'Movie', url: 'u', tvgId: 'movie:3')), isNull);
    });

    test('next episode continues into the next season and stops at the end', () {
      const all = [
        Episode(id: '1', season: 1, number: 1, title: 'a', extension: 'mp4'),
        Episode(id: '2', season: 1, number: 2, title: 'b', extension: 'mp4'),
        Episode(id: '3', season: 2, number: 1, title: 'c', extension: 'mp4'),
      ];
      expect(nextEpisode(all, '1')?.id, '2');
      expect(nextEpisode(all, '2')?.id, '3');
      expect(nextEpisode(all, '3'), isNull);
      expect(nextEpisode(all, 'missing'), isNull);
    });
  });
}
