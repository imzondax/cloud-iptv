import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/services/database.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/secrets.dart';
import 'package:cloud_iptv/services/sync_service.dart';
import 'package:cloud_iptv/services/xtream_client.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements PlaylistBackend {
  PlaylistData? data;
  Object? error;
  Object? epgError;
  List<EpgProgram> epg = const [];

  /// Handed to `onLive` before [data] returns, then [midway] runs.
  PlaylistData? live;
  Future<void> Function()? midway;
  bool offeredLive = false;

  @override
  Future<PlaylistData?> fetch(Source source,
      {Future<void> Function(PlaylistData live)? onLive}) async {
    if (error != null) throw error!;
    offeredLive = onLive != null;
    if (live case final live? when onLive != null) await onLive(live);
    await midway?.call();
    return data;
  }

  @override
  Future<List<EpgProgram>> fetchEpg(
      Source source, Map<String, String> wanted) async {
    if (epgError != null) throw epgError!;
    return epg;
  }
}

PlaylistChannel channel(int source, String id, {String? tvgId}) =>
    PlaylistChannel(
      id: '$source:$id',
      sourceId: source,
      name: id,
      streamUrl: 'http://s.test/$id.ts',
      categoryId: '$source:live:g',
      tvgId: tvgId,
      backendType: BackendType.m3u,
      sortOrder: 0,
    );

PlaylistData catalog(int source, List<PlaylistChannel> channels) => PlaylistData(
      categories: [
        Category(
            id: '$source:live:g',
            sourceId: source,
            name: 'g',
            kind: CategoryKind.live),
      ],
      channels: channels,
      fallbacks: fallbacksFor(channels),
      etag: 'v1',
      epgUrl: 'http://epg.test/g.xml',
    );

void main() {
  late AppDatabase db;
  late FakeBackend backend;
  late SyncService service;
  late Source source;

  Future<List<PlaylistChannel>> stored() =>
      db.watchChannels('${source.id}:live:g', '').first;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    backend = FakeBackend();
    service = SyncService(db, {BackendType.m3u: backend});
    final id = await db.addSource(SourcesCompanion.insert(
        type: BackendType.m3u, name: 'Test', url: 'http://p.test'));
    source = await db.source(id);
  });
  tearDown(() => db.close());

  test('sync stores the catalog and records etag, guide URL and time', () async {
    backend.data = catalog(source.id, [channel(source.id, 'a')]);
    expect(await service.sync(source), isNull);
    expect(await stored(), hasLength(1));
    final after = await db.source(source.id);
    expect(after.etag, 'v1');
    expect(after.epgUrl, 'http://epg.test/g.xml');
    expect(after.lastSyncedAt, isNotNull);
  });

  test('favourites survive a resync, removed channels leave the catalog',
      () async {
    backend.data = catalog(
        source.id, [channel(source.id, 'a'), channel(source.id, 'b')]);
    await service.sync(source);
    await db.setFavorite('${source.id}:a', true);

    backend.data = catalog(source.id, [channel(source.id, 'a')]);
    await service.sync(await db.source(source.id));

    expect((await stored()).map((c) => c.name), ['a']);
    final favorites =
        await db.watchChannels(favoritesCategoryId, '').first;
    expect(favorites.map((c) => c.name), ['a']);
  });

  test('a failed or empty sync keeps the cached catalog', () async {
    backend.data = catalog(source.id, [channel(source.id, 'a')]);
    await service.sync(source);

    backend.data = const PlaylistData();
    expect(await service.sync(source), contains('no streams'));
    expect(await stored(), hasLength(1));

    backend.error = const FormatException('html error page');
    expect(await service.sync(source), contains('invalid response'));
    expect(await stored(), hasLength(1));
  });

  test('an unchanged playlist (304) leaves rows alone and still syncs', () async {
    backend.data = catalog(source.id, [channel(source.id, 'a')]);
    await service.sync(source);
    backend.data = null;
    expect(await service.sync(source), isNull);
    expect(await stored(), hasLength(1));
  });

  test('sync reports each step for the progress line', () async {
    backend.data = catalog(source.id, [channel(source.id, 'a', tvgId: 'x')]);
    final steps = <String>[];
    await service.sync(source, onStep: steps.add);
    expect(steps, [
      'downloading the playlist',
      'saving 1 channels, 0 movies and 0 series',
      'updating the TV guide',
    ]);
  });

  test('search ignores the case of letters like Ø, and takes % and _ as typed',
      () async {
    backend.data = catalog(source.id, [
      for (final name in ['Østfold TV', 'BLÅBÆR', '100% Hits', 'A_B', 'AxB'])
        channel(source.id, name),
    ]);
    await service.sync(source);
    Future<List<String>> search(String text) async =>
        (await db.watchChannels(null, text).first).map((c) => c.name).toList();

    expect(await search('østfold'), ['Østfold TV']);
    expect(await search('blå'), ['BLÅBÆR']);
    expect(await search('0%'), ['100% Hits']);
    expect(await search('a_b'), ['A_B']);
  });

  test('a first sync saves live channels before the rest arrives', () async {
    backend
      ..live = catalog(source.id, [channel(source.id, 'a')])
      ..data = catalog(
          source.id, [channel(source.id, 'a'), channel(source.id, 'b')]);
    int? midway;
    backend.midway = () async => midway = (await stored()).length;
    expect(await service.sync(source), isNull);
    expect(midway, 1);
    expect(await stored(), hasLength(2));

    // Later syncs keep showing the old catalog, so they skip the early write.
    await service.sync(await db.source(source.id));
    expect(backend.offeredLive, isFalse);
  });

  test('a guide failure is reported but keeps the new channels', () async {
    backend.data = catalog(source.id, [channel(source.id, 'a', tvgId: 'x')]);
    backend.epgError = const FormatException('bad xml');
    expect(await service.sync(source), contains('guide not updated'));
    expect(await stored(), hasLength(1));
  });

  test('fallbacks come back in priority order and go with their source',
      () async {
    backend.data = catalog(source.id, [
      channel(source.id, 'a', tvgId: 'x'),
      channel(source.id, 'b', tvgId: 'x'),
      channel(source.id, 'c', tvgId: 'x'),
    ]);
    await service.sync(source);
    final id = '${source.id}:a';
    expect(await db.fallbackUrls(id),
        ['http://s.test/b.ts', 'http://s.test/c.ts']);

    await db.setFavorite(id, true);
    await db.deleteSource(source.id);
    expect(await db.fallbackUrls(id), isEmpty);
    expect(await db.watchFavoriteIds().first, isEmpty);
  });

  test('guide lookup returns overlapping programmes in order', () async {
    final base = DateTime.utc(2030);
    EpgProgram p(int startHour, int stopHour) => EpgProgram(
          channelId: 'x',
          title: '$startHour',
          startTime: base.add(Duration(hours: startHour)),
          stopTime: base.add(Duration(hours: stopHour)),
        );
    await db.saveEpg([p(5, 6), p(1, 3), p(3, 5), p(0, 1)]);
    final found = await db.programs(
        'x', base.add(const Duration(hours: 2)), base.add(const Duration(hours: 4)));
    expect(found.map((e) => e.title), ['1', '3']);

    await db.pruneEpg(base.add(const Duration(hours: 4)));
    expect(await db.programs('x', base, base.add(const Duration(days: 1))),
        hasLength(2));
  });

  test('an item in two categories shows in both, but once in search and '
      'favourites', () async {
    final a = channel(source.id, 'a');
    final data = catalog(source.id, [
      a,
      PlaylistChannel(
        id: a.id,
        sourceId: a.sourceId,
        name: a.name,
        streamUrl: a.streamUrl,
        categoryId: '${source.id}:live:other',
        backendType: a.backendType,
        sortOrder: 1,
      ),
    ]);
    backend.data = data;
    await service.sync(source);
    await db.setFavorite(a.id, true);

    expect(await db.watchChannels('${source.id}:live:g', '').first, hasLength(1));
    expect(await db.watchChannels('${source.id}:live:other', '').first,
        hasLength(1));
    expect(await db.watchChannels(null, 'a').first, hasLength(1));
    expect(await db.watchChannels(favoritesCategoryId, '').first, hasLength(1));
  });

  test('upgrading a v1 database keeps its data and forces a resync', () async {
    final old = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE sources (id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL, name TEXT NOT NULL, url TEXT NOT NULL,
          username TEXT, password TEXT, epg_url TEXT, etag TEXT,
          last_synced_at INTEGER);
        CREATE TABLE settings (key TEXT NOT NULL PRIMARY KEY,
          value TEXT NOT NULL);
        CREATE TABLE channels (id TEXT NOT NULL, source_id INTEGER NOT NULL,
          name TEXT NOT NULL, logo_url TEXT, stream_url TEXT NOT NULL,
          category_id TEXT NOT NULL, tvg_id TEXT, backend_type TEXT NOT NULL,
          sort_order INTEGER NOT NULL, PRIMARY KEY (id));
        CREATE INDEX channels_category ON channels (category_id, sort_order);
        CREATE INDEX channels_source ON channels (source_id);
        CREATE TABLE vod_items (id TEXT NOT NULL, source_id INTEGER NOT NULL,
          title TEXT NOT NULL, poster_url TEXT, stream_url TEXT NOT NULL,
          category_id TEXT NOT NULL, year INTEGER, rating REAL,
          sort_order INTEGER NOT NULL, PRIMARY KEY (id));
        CREATE INDEX vod_category ON vod_items (category_id, sort_order);
        CREATE INDEX vod_source ON vod_items (source_id);
        CREATE TABLE series_items (id TEXT NOT NULL, source_id INTEGER NOT NULL,
          title TEXT NOT NULL, poster_url TEXT, category_id TEXT NOT NULL,
          year INTEGER, rating REAL, sort_order INTEGER NOT NULL,
          PRIMARY KEY (id));
        CREATE INDEX series_category ON series_items (category_id, sort_order);
        CREATE INDEX series_source ON series_items (source_id);
        INSERT INTO sources (type, name, url, etag, last_synced_at)
          VALUES ('xtream', 'Old', 'http://x.test', 'v1', 1700000000);
        INSERT INTO channels VALUES ('1:5', 1, 'Kept', NULL, 'http://s/5.ts',
          '1:live:a', NULL, 'xtream', 0);
        PRAGMA user_version = 1;
      ''');
    }));
    addTearDown(old.close);

    final upgraded = await old.source(1);
    expect(upgraded.name, 'Old');
    expect(upgraded.etag, isNull);
    expect(upgraded.lastSyncedAt, isNull);
    expect((await old.watchChannels('1:live:a', '').first).single.name, 'Kept');

    // The new key must really be in force.
    await old.into(old.channels).insert(ChannelsCompanion.insert(
          id: '1:5',
          sourceId: 1,
          name: 'Kept',
          streamUrl: 'http://s/5.ts',
          categoryId: '1:live:b',
          backendType: BackendType.xtream,
          sortOrder: 1,
          logoUrl: const Value(null),
        ));
    expect(await old.watchChannels('1:live:b', '').first, hasLength(1));
  });

  test('staleness drives startup sync', () {
    final now = DateTime(2030);
    Source at(DateTime? t) => Source(
        id: 1, type: BackendType.m3u, name: 'n', url: 'u', lastSyncedAt: t);
    expect(service.isStale(at(null), now), isTrue);
    expect(service.isStale(at(now.subtract(const Duration(hours: 1))), now),
        isFalse);
    expect(service.isStale(at(now.subtract(const Duration(hours: 7))), now),
        isTrue);
  });
  test('the player gets stored Xtream URLs with the login filled in',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final id = await db.addSource(SourcesCompanion.insert(
        type: BackendType.xtream,
        name: 'X',
        url: 'http://x.test',
        username: const Value('us er')));
    await const Secrets().savePassword(id, 'p/w');

    expect(
        await playableUrls(db, const Secrets(), id, [
          'http://x.test/live/{user}/{pass}/1.m3u8',
          'http://x.test/movie/{user}/{pass}/2.mp4',
        ]),
        [
          'http://x.test/live/us%20er/p%2Fw/1.m3u8',
          'http://x.test/movie/us%20er/p%2Fw/2.mp4',
        ]);
    // M3U links carry no placeholder, and need no source lookup.
    expect(await playableUrls(db, const Secrets(), 999, ['http://m/a.ts']),
        ['http://m/a.ts']);
  });

  test('a start moves an old saved login into the keychain', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final id = await db.addSource(SourcesCompanion.insert(
        type: BackendType.xtream,
        name: 'X',
        url: 'http://x.test',
        username: const Value('us er'),
        password: const Value('p/w')));
    final xtream = await db.source(id);
    PlaylistChannel live(String streamId) => PlaylistChannel(
          id: '$id:$streamId',
          sourceId: id,
          name: streamId,
          streamUrl: 'http://x.test/live/us%20er/p%2Fw/$streamId.ts',
          categoryId: '$id:live:g',
          tvgId: 'same',
          backendType: BackendType.xtream,
          sortOrder: 0,
        );
    await db.replaceCatalog(xtream, catalog(id, [live('1'), live('2')]));
    await db.saveProgress(
        VodItem(
            id: '$id:ep:9',
            sourceId: id,
            title: 'Episode',
            streamUrl: 'http://x.test/series/us%20er/p%2Fw/9.mp4',
            categoryId: 'c',
            sortOrder: 0),
        const Duration(minutes: 5),
        const Duration(minutes: 40));

    await moveLoginsToKeychain(db, const Secrets());
    await moveLoginsToKeychain(db, const Secrets()); // Nothing left to move.

    final moved = await db.source(id);
    expect(moved.password, isNull);
    expect(await const Secrets().password(moved), 'p/w');
    final urls = [
      ...(await db.watchChannels('$id:live:g', '').first).map((c) => c.streamUrl),
      ...await db.fallbackUrls('$id:1'),
      (await db.watchKeepWatching(5).first).single.streamUrl,
    ];
    expect(urls, hasLength(4));
    for (final url in urls) {
      expect(url, contains('/{user}/{pass}/'));
      expect(withLogin(url, 'us er', 'p/w'), contains('/us%20er/p%2Fw/'));
    }
  });
}
