import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../features/playlist/channel.dart';

part 'database.g.dart';

@DataClassName('ChannelRow')
class Channels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get url => text()();
  TextColumn get logo => text().withDefault(const Constant(''))();
  TextColumn get groupTitle => text().withDefault(const Constant(''))();
  TextColumn get tvgId => text().withDefault(const Constant(''))();
  IntColumn get tvgChno => integer().nullable()();
  IntColumn get number => integer()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Favorites extends Table {
  TextColumn get channelId => text()();
  DateTimeColumn get addedAt => dateTime()();

  /// User-defined order (also the favorite's quick number, 1-based).
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {channelId};
}

class History extends Table {
  TextColumn get channelId => text()();
  DateTimeColumn get watchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// Resume points for movies and episodes.
class PlaybackPositions extends Table {
  TextColumn get mediaId => text()();
  IntColumn get positionMs => integer()();
  IntColumn get durationMs => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  // What to show in "Continue watching" (v3).
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get url => text().withDefault(const Constant(''))();
  TextColumn get logo => text().withDefault(const Constant(''))();

  /// `movie:ID` or `series:ID`.
  TextColumn get ref => text().withDefault(const Constant(''))();

  /// Finished (v4): shows a check mark, not in "Continue watching".
  BoolColumn get watched => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {mediaId};
}

@DriftDatabase(tables: [Channels, Favorites, History, PlaybackPositions])
class AppDatabase extends _$AppDatabase {
  AppDatabase(File file) : super(NativeDatabase.createInBackground(file));
  AppDatabase.forTesting(super.e);

  static const historyLimit = 50;

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(favorites, favorites.sortOrder);
            await m.createTable(playbackPositions);
          } else if (from < 3) {
            // v2 -> v3
            await m.addColumn(playbackPositions, playbackPositions.title);
            await m.addColumn(playbackPositions, playbackPositions.url);
            await m.addColumn(playbackPositions, playbackPositions.logo);
            await m.addColumn(playbackPositions, playbackPositions.ref);
          }
          if (from >= 2 && from < 4) {
            await m.addColumn(playbackPositions, playbackPositions.watched);
          }
        },
      );

  Future<List<Channel>> loadChannels() async {
    final rows = await (select(channels)..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
    return [
      for (final r in rows)
        Channel(
          id: r.id,
          name: r.name,
          url: r.url,
          logo: r.logo,
          group: r.groupTitle,
          tvgId: r.tvgId,
          tvgChno: r.tvgChno,
          number: r.number,
          order: r.sortOrder,
        ),
    ];
  }

  /// Replaces the cached playlist atomically: the old rows are only removed
  /// inside the same transaction that inserts the new, already parsed ones.
  Future<void> replaceChannels(List<Channel> list) {
    return transaction(() async {
      await delete(channels).go();
      await batch((b) {
        b.insertAll(channels, [
          for (final c in list)
            ChannelsCompanion.insert(
              id: c.id,
              name: c.name,
              url: c.url,
              logo: Value(c.logo),
              groupTitle: Value(c.group),
              tvgId: Value(c.tvgId),
              tvgChno: Value(c.tvgChno),
              number: c.number,
              sortOrder: c.order,
            ),
        ]);
      });
    });
  }

  Future<void> clearChannels() => delete(channels).go();

  /// In the user's order.
  Future<List<String>> loadFavorites() async {
    final rows = await (select(favorites)
          ..orderBy([(f) => OrderingTerm.asc(f.sortOrder), (f) => OrderingTerm.asc(f.addedAt)]))
        .get();
    return rows.map((f) => f.channelId).toList();
  }

  Future<void> setFavorite(String channelId, bool favorite) async {
    if (favorite) {
      final max = favorites.sortOrder.max();
      final last = await (selectOnly(favorites)..addColumns([max])).map((r) => r.read(max)).getSingle();
      await into(favorites).insertOnConflictUpdate(
        FavoritesCompanion.insert(channelId: channelId, addedAt: DateTime.now(), sortOrder: Value((last ?? 0) + 1)),
      );
    } else {
      await (delete(favorites)..where((f) => f.channelId.equals(channelId))).go();
    }
  }

  Future<void> saveFavoriteOrder(List<String> ids) => batch((b) {
        for (var i = 0; i < ids.length; i++) {
          b.update(favorites, FavoritesCompanion(sortOrder: Value(i + 1)),
              where: (f) => f.channelId.equals(ids[i]));
        }
      });

  /// Where to resume; null when not started or already watched.
  Future<Duration?> loadPosition(String mediaId) async {
    final row = await (select(playbackPositions)..where((p) => p.mediaId.equals(mediaId))).getSingleOrNull();
    return row == null || row.watched ? null : Duration(milliseconds: row.positionMs);
  }

  Future<void> markWatched(Channel media, Duration duration) =>
      into(playbackPositions).insertOnConflictUpdate(PlaybackPositionsCompanion.insert(
        mediaId: media.id,
        positionMs: 0,
        durationMs: duration.inMilliseconds,
        updatedAt: DateTime.now(),
        title: Value(media.name),
        url: Value(media.url),
        logo: Value(media.logo),
        ref: Value(media.tvgId),
        watched: const Value(true),
      ));

  Future<void> savePosition(Channel media, Duration position, Duration duration) =>
      into(playbackPositions).insertOnConflictUpdate(PlaybackPositionsCompanion.insert(
        mediaId: media.id,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAt: DateTime.now(),
        title: Value(media.name),
        url: Value(media.url),
        logo: Value(media.logo),
        ref: Value(media.tvgId),
        watched: const Value(false),
      ));

  /// Started movies/episodes, most recent first (live-updating).
  Stream<List<PlaybackPosition>> watchPositions() =>
      (select(playbackPositions)..orderBy([(p) => OrderingTerm.desc(p.updatedAt)])).watch();

  Future<void> deletePosition(String mediaId) =>
      (delete(playbackPositions)..where((p) => p.mediaId.equals(mediaId))).go();

  /// Most recent first.
  Future<List<String>> loadHistory() async {
    final rows = await (select(history)
          ..orderBy([(h) => OrderingTerm.desc(h.watchedAt)])
          ..limit(historyLimit))
        .get();
    return rows.map((h) => h.channelId).toList();
  }

  Future<void> addHistory(String channelId) async {
    await into(history).insertOnConflictUpdate(
      HistoryCompanion.insert(channelId: channelId, watchedAt: DateTime.now()),
    );
    // Keep the table small.
    await customStatement(
      'DELETE FROM history WHERE channel_id NOT IN '
      '(SELECT channel_id FROM history ORDER BY watched_at DESC LIMIT $historyLimit)',
    );
  }
}
