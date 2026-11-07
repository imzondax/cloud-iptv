import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'playlist_backend.dart';
import 'tmdb.dart' show CatalogTitle;

part 'database.g.dart';

@UseRowClass(Source)
class Sources extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get type => textEnum<BackendType>()();
  TextColumn get name => text()();
  TextColumn get url => text()();
  TextColumn get username => text().nullable()();
  TextColumn get password => text().nullable()();
  TextColumn get epgUrl => text().nullable()();
  TextColumn get etag => text().nullable()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
}

@UseRowClass(Category, generateInsertable: true)
@TableIndex(name: 'categories_kind', columns: {#kind})
class Categories extends Table {
  TextColumn get id => text()();
  IntColumn get sourceId => integer()();
  TextColumn get name => text()();
  TextColumn get kind => textEnum<CategoryKind>()();

  @override
  Set<Column> get primaryKey => {id};
}

@UseRowClass(PlaylistChannel, generateInsertable: true)
@TableIndex(name: 'channels_category', columns: {#categoryId, #sortOrder})
@TableIndex(name: 'channels_source', columns: {#sourceId})
class Channels extends Table {
  TextColumn get id => text()();
  IntColumn get sourceId => integer()();
  TextColumn get name => text()();
  TextColumn get logoUrl => text().nullable()();
  TextColumn get streamUrl => text()();
  TextColumn get categoryId => text()();
  TextColumn get tvgId => text().nullable()();
  TextColumn get backendType => textEnum<BackendType>()();
  IntColumn get sortOrder => integer()();
  IntColumn get archiveDays => integer().withDefault(const Constant(0))();

  /// Panels list an item once per category, under the same id.
  @override
  Set<Column> get primaryKey => {id, categoryId};
}

@UseRowClass(VodItem, generateInsertable: true)
@TableIndex(name: 'vod_category', columns: {#categoryId, #sortOrder})
@TableIndex(name: 'vod_source', columns: {#sourceId})
class VodItems extends Table {
  TextColumn get id => text()();
  IntColumn get sourceId => integer()();
  TextColumn get title => text()();
  TextColumn get posterUrl => text().nullable()();
  TextColumn get streamUrl => text()();
  TextColumn get categoryId => text()();
  IntColumn get year => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get sortOrder => integer()();

  /// Panels list an item once per category, under the same id.
  @override
  Set<Column> get primaryKey => {id, categoryId};
}

@UseRowClass(SeriesItem, generateInsertable: true)
@TableIndex(name: 'series_category', columns: {#categoryId, #sortOrder})
@TableIndex(name: 'series_source', columns: {#sourceId})
class SeriesItems extends Table {
  TextColumn get id => text()();
  IntColumn get sourceId => integer()();
  TextColumn get title => text()();
  TextColumn get posterUrl => text().nullable()();
  TextColumn get categoryId => text()();
  IntColumn get year => integer().nullable()();
  RealColumn get rating => real().nullable()();
  IntColumn get sortOrder => integer()();

  /// Panels list an item once per category, under the same id.
  @override
  Set<Column> get primaryKey => {id, categoryId};
}

/// The primary key doubles as the guide's lookup index.
@UseRowClass(EpgProgram, generateInsertable: true)
class EpgPrograms extends Table {
  TextColumn get channelId => text()();
  TextColumn get title => text()();
  DateTimeColumn get startTime => dateTime()();
  DateTimeColumn get stopTime => dateTime()();
  TextColumn get description => text().nullable()();

  @override
  Set<Column> get primaryKey => {channelId, startTime};
}

@UseRowClass(StreamFallback, generateInsertable: true)
class StreamFallbacks extends Table {
  TextColumn get channelId => text()();
  TextColumn get url => text()();
  IntColumn get priority => integer()();

  @override
  Set<Column> get primaryKey => {channelId, url};
}

/// Kept apart from [Channels] so a catalog rewrite leaves favourites intact.
class Favorites extends Table {
  TextColumn get channelId => text()();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// Where a movie or episode was left. A snapshot, because episodes are not
/// stored in the catalog.
// shortcut: streamUrl keeps the login it was saved with, so editing a source's
// password leaves old entries unplayable until they are watched again.
class WatchProgress extends Table {
  TextColumn get itemId => text()();
  IntColumn get sourceId => integer()();
  TextColumn get title => text()();
  TextColumn get posterUrl => text().nullable()();
  TextColumn get streamUrl => text()();
  IntColumn get positionMs => integer()();
  IntColumn get durationMs => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {itemId};
}

/// Favourite movies and series. Separate from [Favorites], because live,
/// movie and series ids overlap.
class FavoriteTitles extends Table {
  TextColumn get itemId => text()();
  TextColumn get kind => textEnum<CategoryKind>()();

  @override
  Set<Column> get primaryKey => {itemId, kind};
}

/// Kept apart from [Categories], which every sync rewrites.
class CategoryRules extends Table {
  TextColumn get categoryId => text()();
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {categoryId};
}

class Reminders extends Table {
  TextColumn get channelId => text()();
  TextColumn get title => text()();
  DateTimeColumn get startTime => dateTime()();

  @override
  Set<Column> get primaryKey => {channelId, startTime};
}

class RecentChannels extends Table {
  TextColumn get channelId => text()();
  DateTimeColumn get watchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {channelId};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

const favoritesCategoryId = '__favorites__';
const _unlockedKey = 'parental_unlocked';

/// Unique items per source. `guide` counts channels that have programmes.
typedef SourceStats = ({int live, int movies, int series, int guide});

// shortcut: search shows the first 500 matches, add paging if users need more.
const _searchLimit = 500;

/// Search and favourites span categories, where one item has several rows.
List<T> _uniqueById<T>(List<T> rows, String Function(T) id) {
  final seen = <String>{};
  return rows.where((row) => seen.add(id(row))).toList();
}

@DriftDatabase(tables: [
  Sources, Categories, Channels, VodItems, SeriesItems, EpgPrograms,
  StreamFallbacks, Favorites, Settings, WatchProgress, RecentChannels,
  FavoriteTitles, CategoryRules, Reminders,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ??
            driftDatabase(
              name: 'cloud_iptv',
              native: const DriftNativeOptions(
                databaseDirectory: getApplicationSupportDirectory,
              ),
            ));

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.alterTable(TableMigration(
              channels,
              newColumns: [channels.archiveDays],
            ));
            await m.alterTable(TableMigration(vodItems));
            await m.alterTable(TableMigration(seriesItems));
            // Rows lost to the old key only come back with a full download.
            await update(sources).write(const SourcesCompanion(
              etag: Value(null),
              lastSyncedAt: Value(null),
            ));
          }
          if (from < 3) {
            await m.createTable(watchProgress);
            await m.createTable(recentChannels);
          }
          if (from < 4) {
            // Version 1 databases got this column in their rebuild above.
            if (from >= 2) await m.addColumn(channels, channels.archiveDays);
            await m.createTable(favoriteTitles);
            await m.createTable(categoryRules);
            await m.createTable(reminders);
            // Catch-up details only arrive with a full download.
            await update(sources).write(const SourcesCompanion(
              etag: Value(null),
              lastSyncedAt: Value(null),
            ));
          }
        },
        // A PIN unlock lasts until the app closes.
        beforeOpen: (details) async {
          if (details.versionBefore != null) {
            await (delete(settings)..where((s) => s.key.equals(_unlockedKey)))
                .go();
          }
        },
      );

  /// Leaves out what sits in hidden categories, and in locked ones until the
  /// PIN has been entered. The session flag lives in [settings], so that
  /// running queries update by themselves when it changes.
  Expression<bool> _shown(GeneratedColumn<String> categoryId) {
    final unlocked = select(settings)..where((s) => s.key.equals(_unlockedKey));
    final blocked = selectOnly(categoryRules)
      ..addColumns([categoryRules.categoryId])
      ..where(categoryRules.hidden |
          (categoryRules.locked & notExistsQuery(unlocked)));
    return categoryId.isNotInQuery(blocked);
  }

  // Sources

  Stream<List<Source>> watchSources() => select(sources).watch();
  Future<List<Source>> allSources() => select(sources).get();

  Future<Source> source(int id) =>
      (select(sources)..where((s) => s.id.equals(id))).getSingle();

  Future<int> addSource(SourcesCompanion source) =>
      into(sources).insert(source);

  Future<void> updateSource(int id, SourcesCompanion changes) =>
      (update(sources)..where((s) => s.id.equals(id))).write(changes);

  Future<void> deleteSource(int id) => transaction(() async {
        await _deleteCatalog(id);
        await (delete(favorites)..where((f) => f.channelId.like('$id:%'))).go();
        await (delete(watchProgress)..where((w) => w.sourceId.equals(id))).go();
        await (delete(favoriteTitles)..where((f) => f.itemId.like('$id:%')))
            .go();
        await (delete(categoryRules)
              ..where((r) => r.categoryId.like('$id:%')))
            .go();
        await (delete(reminders)..where((r) => r.channelId.like('$id:%'))).go();
        await (delete(recentChannels)
              ..where((r) => r.channelId.like('$id:%')))
            .go();
        await (delete(sources)..where((s) => s.id.equals(id))).go();
      });

  Future<void> _deleteCatalog(int id) async {
    await (delete(streamFallbacks)..where((f) => f.channelId.like('$id:%'))).go();
    await (delete(categories)..where((c) => c.sourceId.equals(id))).go();
    await (delete(channels)..where((c) => c.sourceId.equals(id))).go();
    await (delete(vodItems)..where((v) => v.sourceId.equals(id))).go();
    await (delete(seriesItems)..where((s) => s.sourceId.equals(id))).go();
  }

  /// Atomic, so a failure part-way keeps the previous catalog.
  Future<void> replaceCatalog(Source source, PlaylistData data) =>
      transaction(() async {
        await _deleteCatalog(source.id);
        await batch((b) {
          const mode = InsertMode.insertOrReplace;
          b.insertAll(categories, data.categories.map((e) => e.toInsertable()),
              mode: mode);
          b.insertAll(channels, data.channels.map((e) => e.toInsertable()),
              mode: mode);
          b.insertAll(vodItems, data.vod.map((e) => e.toInsertable()),
              mode: mode);
          b.insertAll(seriesItems, data.series.map((e) => e.toInsertable()),
              mode: mode);
          b.insertAll(streamFallbacks,
              data.fallbacks.map((e) => e.toInsertable()), mode: mode);
        });
        await (update(sources)..where((s) => s.id.equals(source.id))).write(
          SourcesCompanion(
            etag: Value(data.etag),
            epgUrl: Value(source.epgUrl ?? data.epgUrl),
          ),
        );
      });

  Future<void> markSynced(int id) =>
      (update(sources)..where((s) => s.id.equals(id))).write(
        SourcesCompanion(lastSyncedAt: Value(DateTime.now())),
      );

  // Browsing

  /// Only categories with something in them: providers list plenty of empty
  /// ones, and one could otherwise open as the default.
  Stream<List<Category>> watchCategories(CategoryKind kind) {
    final BaseSelectStatement used = switch (kind) {
      CategoryKind.live => selectOnly(channels)
        ..addColumns([channels.categoryId]),
      CategoryKind.vod => selectOnly(vodItems)
        ..addColumns([vodItems.categoryId]),
      CategoryKind.series => selectOnly(seriesItems)
        ..addColumns([seriesItems.categoryId]),
    };
    return (select(categories)
          ..where((c) =>
              c.kind.equalsValue(kind) & c.id.isInQuery(used) & _shown(c.id))
          ..orderBy([(c) => OrderingTerm.asc(c.name)]))
        .watch();
  }

  // shortcut: a category loads whole (off the UI thread), add paging if a
  // provider ships one group with 100k+ entries.
  Stream<List<PlaylistChannel>> watchChannels(String? categoryId, String search) {
    if (categoryId == favoritesCategoryId && search.isEmpty) {
      final query = select(channels).join([
        innerJoin(favorites, favorites.channelId.equalsExp(channels.id)),
      ])
        ..where(_shown(channels.categoryId))
        ..orderBy([OrderingTerm.asc(channels.name)]);
      return query
          .map((row) => row.readTable(channels))
          .watch()
          .map((rows) => _uniqueById(rows, (c) => c.id));
    }
    final query = select(channels);
    if (search.isNotEmpty) {
      query
        ..where((c) => c.name.contains(search) & _shown(c.categoryId))
        ..limit(_searchLimit);
    } else {
      query.where((c) => c.categoryId.equalsNullable(categoryId));
    }
    query.orderBy([(c) => OrderingTerm.asc(c.sortOrder)]);
    return query.watch().map((rows) => _uniqueById(rows, (c) => c.id));
  }

  Stream<List<VodItem>> watchVod(String? categoryId, String search) {
    if (categoryId == favoritesCategoryId && search.isEmpty) {
      final query = select(vodItems).join([
        innerJoin(
            favoriteTitles,
            favoriteTitles.itemId.equalsExp(vodItems.id) &
                favoriteTitles.kind.equalsValue(CategoryKind.vod)),
      ])
        ..where(_shown(vodItems.categoryId))
        ..orderBy([OrderingTerm.asc(vodItems.title)]);
      return query
          .map((row) => row.readTable(vodItems))
          .watch()
          .map((rows) => _uniqueById(rows, (v) => v.id));
    }
    final query = select(vodItems);
    if (search.isNotEmpty) {
      query
        ..where((v) => v.title.contains(search) & _shown(v.categoryId))
        ..limit(_searchLimit);
    } else {
      query.where((v) => v.categoryId.equalsNullable(categoryId));
    }
    query.orderBy([(v) => OrderingTerm.asc(v.sortOrder)]);
    return query.watch().map((rows) => _uniqueById(rows, (v) => v.id));
  }

  Stream<List<SeriesItem>> watchSeries(String? categoryId, String search) {
    if (categoryId == favoritesCategoryId && search.isEmpty) {
      final query = select(seriesItems).join([
        innerJoin(
            favoriteTitles,
            favoriteTitles.itemId.equalsExp(seriesItems.id) &
                favoriteTitles.kind.equalsValue(CategoryKind.series)),
      ])
        ..where(_shown(seriesItems.categoryId))
        ..orderBy([OrderingTerm.asc(seriesItems.title)]);
      return query
          .map((row) => row.readTable(seriesItems))
          .watch()
          .map((rows) => _uniqueById(rows, (s) => s.id));
    }
    final query = select(seriesItems);
    if (search.isNotEmpty) {
      query
        ..where((s) => s.title.contains(search) & _shown(s.categoryId))
        ..limit(_searchLimit);
    } else {
      query.where((s) => s.categoryId.equalsNullable(categoryId));
    }
    query.orderBy([(s) => OrderingTerm.asc(s.sortOrder)]);
    return query.watch().map((rows) => _uniqueById(rows, (s) => s.id));
  }

  /// Live channels per category id.
  Stream<Map<String, int>> watchCategoryCounts() {
    final count = channels.id.count();
    final query = selectOnly(channels)
      ..addColumns([channels.categoryId, count])
      ..groupBy([channels.categoryId]);
    return query.watch().map((rows) => {
          for (final r in rows) r.read(channels.categoryId)!: r.read(count)!,
        });
  }

  Stream<SourceStats> watchSourceStats(int sourceId) => customSelect(
        '''
        SELECT
          (SELECT COUNT(DISTINCT id) FROM channels WHERE source_id = ?1) AS live,
          (SELECT COUNT(DISTINCT id) FROM vod_items WHERE source_id = ?1) AS movies,
          (SELECT COUNT(DISTINCT id) FROM series_items WHERE source_id = ?1) AS series,
          (SELECT COUNT(DISTINCT tvg_id) FROM channels WHERE source_id = ?1
            AND tvg_id IN (SELECT channel_id FROM epg_programs)) AS guide
        ''',
        variables: [Variable.withInt(sourceId)],
        readsFrom: {channels, vodItems, seriesItems, epgPrograms},
      ).watchSingle().map((r) => (
            live: r.read<int>('live'),
            movies: r.read<int>('movies'),
            series: r.read<int>('series'),
            guide: r.read<int>('guide'),
          ));

  // Category rules

  /// Every category, whatever its rules, for managing them.
  Stream<List<Category>> watchAllCategories() => (select(categories)
        ..orderBy([
          (c) => OrderingTerm.asc(c.kind),
          (c) => OrderingTerm.asc(c.name),
        ]))
      .watch();

  Stream<Map<String, CategoryRule>> watchCategoryRules() => select(categoryRules)
      .watch()
      .map((rows) => {for (final r in rows) r.categoryId: r});

  Future<void> setCategoryRule(String categoryId,
          {required bool hidden, required bool locked}) =>
      into(categoryRules).insertOnConflictUpdate(CategoryRulesCompanion.insert(
        categoryId: categoryId,
        hidden: Value(hidden),
        locked: Value(locked),
      ));

  /// Without a PIN, a lock could never be opened again.
  Future<void> clearLocks() => update(categoryRules)
      .write(const CategoryRulesCompanion(locked: Value(false)));

  Future<void> setUnlocked(bool unlocked) => unlocked
      ? saveSetting(_unlockedKey, '1')
      : (delete(settings)..where((s) => s.key.equals(_unlockedKey))).go();

  Stream<bool> watchUnlocked() => watchSetting(_unlockedKey).map((v) => v != null);

  // Favourite movies and series

  Stream<Set<String>> watchFavoriteTitles(CategoryKind kind) =>
      (select(favoriteTitles)..where((f) => f.kind.equalsValue(kind)))
          .watch()
          .map((rows) => rows.map((f) => f.itemId).toSet());

  Future<void> setFavoriteTitle(
          String itemId, CategoryKind kind, bool favorite) =>
      favorite
          ? into(favoriteTitles).insertOnConflictUpdate(
              FavoriteTitlesCompanion.insert(itemId: itemId, kind: kind))
          : (delete(favoriteTitles)
                ..where((f) =>
                    f.itemId.equals(itemId) & f.kind.equalsValue(kind)))
              .go();

  // Reminders

  Stream<List<Reminder>> watchReminders() => select(reminders).watch();

  Future<void> addReminder(String channelId, EpgProgram program) =>
      into(reminders).insertOnConflictUpdate(RemindersCompanion.insert(
        channelId: channelId,
        title: program.title,
        startTime: program.startTime,
      ));

  Future<void> removeReminder(String channelId, DateTime startTime) =>
      (delete(reminders)
            ..where((r) =>
                r.channelId.equals(channelId) &
                r.startTime.equals(startTime)))
          .go();

  /// Takes the reminders starting by [until], so each fires only once.
  Future<List<Reminder>> takeDueReminders(DateTime until) =>
      transaction(() async {
        final due = (select(reminders)
          ..where((r) => r.startTime.isSmallerOrEqualValue(until)));
        final rows = await due.get();
        await (delete(reminders)
              ..where((r) => r.startTime.isSmallerOrEqualValue(until)))
            .go();
        return rows;
      });

  Future<PlaylistChannel?> channelById(String id) async =>
      (await (select(channels)
                ..where((c) => c.id.equals(id))
                ..limit(1))
              .get())
          .firstOrNull;

  // Watch history

  Future<void> saveProgress(VodItem item, Duration position, Duration duration) =>
      into(watchProgress).insertOnConflictUpdate(WatchProgressCompanion.insert(
        itemId: item.id,
        sourceId: item.sourceId,
        title: item.title,
        posterUrl: Value(item.posterUrl),
        streamUrl: item.streamUrl,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAt: DateTime.now(),
      ));

  Future<void> clearProgress(String itemId) =>
      (delete(watchProgress)..where((w) => w.itemId.equals(itemId))).go();

  Future<Duration?> progress(String itemId) async {
    final row = await (select(watchProgress)
          ..where((w) => w.itemId.equals(itemId)))
        .getSingleOrNull();
    return row == null ? null : Duration(milliseconds: row.positionMs);
  }

  Stream<List<WatchProgressData>> watchKeepWatching(int limit) {
    final blocked = selectOnly(vodItems)
      ..addColumns([vodItems.id])
      ..where(_shown(vodItems.categoryId).not());
    return (select(watchProgress)
          ..where((w) => w.itemId.isNotInQuery(blocked))
          ..orderBy([(w) => OrderingTerm.desc(w.updatedAt)])
          ..limit(limit))
        .watch();
  }

  Future<void> markChannelWatched(String channelId) =>
      into(recentChannels).insertOnConflictUpdate(
          RecentChannelsCompanion.insert(
              channelId: channelId, watchedAt: DateTime.now()));

  Stream<List<PlaylistChannel>> watchRecentChannels(int limit) {
    final query = select(channels).join([
      innerJoin(
          recentChannels, recentChannels.channelId.equalsExp(channels.id)),
    ])
      ..where(_shown(channels.categoryId))
      ..orderBy([OrderingTerm.desc(recentChannels.watchedAt)])
      ..limit(limit * 4);
    return query.map((row) => row.readTable(channels)).watch().map(
        (rows) => _uniqueById(rows, (c) => c.id).take(limit).toList());
  }

  // Recommendations

  Future<List<CatalogTitle>> catalogTitles(CategoryKind kind) async {
    if (kind == CategoryKind.series) {
      final q = selectOnly(seriesItems)
        ..addColumns([seriesItems.id, seriesItems.title, seriesItems.year])
        ..where(_shown(seriesItems.categoryId));
      return q
          .map((r) => (
                id: r.read(seriesItems.id)!,
                title: r.read(seriesItems.title)!,
                year: r.read(seriesItems.year),
              ))
          .get();
    }
    final q = selectOnly(vodItems)
      ..addColumns([vodItems.id, vodItems.title, vodItems.year])
      ..where(_shown(vodItems.categoryId));
    return q
        .map((r) => (
              id: r.read(vodItems.id)!,
              title: r.read(vodItems.title)!,
              year: r.read(vodItems.year),
            ))
        .get();
  }

  /// In the order of [ids].
  Future<List<VodItem>> vodByIds(List<String> ids) async {
    final rows = await (select(vodItems)..where((v) => v.id.isIn(ids))).get();
    final byId = {for (final r in rows) r.id: r};
    return [for (final id in ids) ?byId[id]];
  }

  /// In the order of [ids].
  Future<List<SeriesItem>> seriesByIds(List<String> ids) async {
    final rows =
        await (select(seriesItems)..where((s) => s.id.isIn(ids))).get();
    final byId = {for (final r in rows) r.id: r};
    return [for (final id in ids) ?byId[id]];
  }

  // shortcut: ranks by favourites, the guide and provider ratings only, as
  // nothing records what was watched. Use watch history once that exists.

  /// Favourites, then what is on air now, then the rest of the lineup.
  Future<List<PlaylistChannel>> recommendedChannels(
      DateTime now, int limit) async {
    // Rows repeat per category, so fetch extra to still fill [limit].
    final rows = limit * 4;
    final airing = selectOnly(epgPrograms)
      ..addColumns([epgPrograms.channelId])
      ..where(epgPrograms.startTime.isSmallerOrEqualValue(now) &
          epgPrograms.stopTime.isBiggerThanValue(now));
    final picks = [
      ...await (select(channels).join([
        innerJoin(favorites, favorites.channelId.equalsExp(channels.id)),
      ])
            ..where(_shown(channels.categoryId))
            ..orderBy([OrderingTerm.asc(channels.name)])
            ..limit(rows))
          .map((row) => row.readTable(channels))
          .get(),
      ...await (select(channels)
            ..where((c) =>
                coalesce([c.tvgId, c.id]).isInQuery(airing) &
                _shown(c.categoryId))
            ..orderBy([(c) => OrderingTerm.asc(c.sortOrder)])
            ..limit(rows))
          .get(),
      ...await (select(channels)
            ..where((c) => _shown(c.categoryId))
            ..orderBy([(c) => OrderingTerm.asc(c.sortOrder)])
            ..limit(rows))
          .get(),
    ];
    return _uniqueById(picks, (c) => c.id).take(limit).toList();
  }

  Stream<List<VodItem>> watchTopVod(int limit) => (select(vodItems)
        ..where((v) => _shown(v.categoryId))
        ..orderBy([
          (v) => OrderingTerm.desc(v.rating),
          (v) => OrderingTerm.desc(v.year),
          (v) => OrderingTerm.asc(v.sortOrder),
        ])
        ..limit(limit * 4))
      .watch()
      .map((rows) => _uniqueById(rows, (v) => v.id).take(limit).toList());

  Stream<List<SeriesItem>> watchTopSeries(int limit) => (select(seriesItems)
        ..where((s) => _shown(s.categoryId))
        ..orderBy([
          (s) => OrderingTerm.desc(s.rating),
          (s) => OrderingTerm.desc(s.year),
          (s) => OrderingTerm.asc(s.sortOrder),
        ])
        ..limit(limit * 4))
      .watch()
      .map((rows) => _uniqueById(rows, (s) => s.id).take(limit).toList());

  // Favourites

  Stream<Set<String>> watchFavoriteIds() => select(favorites)
      .watch()
      .map((rows) => rows.map((f) => f.channelId).toSet());

  Future<void> setFavorite(String channelId, bool favorite) => favorite
      ? into(favorites).insertOnConflictUpdate(
          FavoritesCompanion.insert(channelId: channelId))
      : (delete(favorites)..where((f) => f.channelId.equals(channelId))).go();

  // Failover

  Future<List<String>> fallbackUrls(String channelId) async {
    final rows = await (select(streamFallbacks)
          ..where((f) => f.channelId.equals(channelId))
          ..orderBy([(f) => OrderingTerm.asc(f.priority)]))
        .get();
    return rows.map((f) => f.url).toList();
  }

  // EPG

  /// Each tvg-id of a source, mapped to one channel carrying it.
  Future<Map<String, String>> epgChannels(int sourceId) async {
    final query = selectOnly(channels)
      ..addColumns([channels.tvgId, channels.id])
      ..where(channels.sourceId.equals(sourceId) & channels.tvgId.isNotNull());
    final rows = await query.get();
    return {
      for (final r in rows) r.read(channels.tvgId)!: r.read(channels.id)!,
    };
  }

  Future<void> saveEpg(List<EpgProgram> programs) => batch((b) => b.insertAll(
      epgPrograms, programs.map((e) => e.toInsertable()),
      mode: InsertMode.insertOrReplace));

  Future<void> pruneEpg(DateTime before) =>
      (delete(epgPrograms)..where((e) => e.stopTime.isSmallerThanValue(before)))
          .go();

  Future<List<EpgProgram>> programs(String key, DateTime from, DateTime to) =>
      (select(epgPrograms)
            ..where((e) =>
                e.channelId.equals(key) &
                e.startTime.isSmallerThanValue(to) &
                e.stopTime.isBiggerThanValue(from))
            ..orderBy([(e) => OrderingTerm.asc(e.startTime)]))
          .get();

  // Settings

  Future<String?> setting(String key) async =>
      (await (select(settings)..where((s) => s.key.equals(key)))
              .getSingleOrNull())
          ?.value;

  Future<void> deleteSetting(String key) =>
      (delete(settings)..where((s) => s.key.equals(key))).go();

  Stream<String?> watchSetting(String key) =>
      (select(settings)..where((s) => s.key.equals(key)))
          .watchSingleOrNull()
          .map((s) => s?.value);

  Future<void> saveSetting(String key, String value) => into(settings)
      .insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
}
