import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/player/iptv_player.dart';
import 'package:cloud_iptv/providers/providers.dart';
import 'package:cloud_iptv/services/database.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/tmdb.dart';
import 'package:cloud_iptv/ui/dashboard_tab.dart';
import 'package:cloud_iptv/ui/home_screen.dart';
import 'package:cloud_iptv/ui/library_tab.dart';
import 'package:cloud_iptv/ui/player_screen.dart';
import 'package:cloud_iptv/ui/theme.dart';
import 'package:cloud_iptv/ui/widgets.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one series' episodes; anything else would be an unexpected call.
class EpisodesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.uri.host == 'api.themoviedb.org') {
      if (options.queryParameters['api_key'] == 'bad') {
        return ResponseBody.fromString('{}', 401);
      }
      final tv = options.path.contains('/tv');
      final first = options.queryParameters['page'] == '1';
      Map<String, Object> title(String name, String date, String language) =>
          tv
              ? {'name': name, 'original_name': name,
                  'first_air_date': date, 'original_language': language}
              : {'title': name, 'original_title': name,
                  'release_date': date, 'original_language': language};
      return ResponseBody.fromString(
        jsonEncode({
          'results': !first
              ? []
              : [
                  title('Granite Drama', '2021-02-01', 'en'),
                  title('Fjord One', '2022-02-01', 'hi'),
                  title('Not On This Provider', '2024-01-01', 'en'),
                  title('Metro Music', '2021-01-01', 'fr'),
                ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    Map<String, Object> episode(int season, int n) => {
          'id': '$season$n',
          'season': season,
          'episode_num': n,
          'title': 'Episode title number $n',
          'container_extension': 'mp4',
          'info': {'duration': '00:4$n:10'},
        };
    return ResponseBody.fromString(
        jsonEncode({
          'episodes': {
            '1': [for (var n = 1; n <= 6; n++) episode(1, n)],
            '2': [for (var n = 1; n <= 3; n++) episode(2, n)],
          }
        }),
        200);
  }

  @override
  void close({bool force = false}) {}
}

/// Records what would play, without starting libmpv.
class FakeActiveStream extends ActiveStream {
  static final played = <String>[];

  @override
  Future<void> playChannel(PlaylistChannel channel,
      {List<PlaylistChannel>? playlist}) async {
    played.add(channel.name);
  }

  @override
  Future<void> playVod(VodItem item) async => played.add(item.title);

  @override
  Future<void> stop() async {}
}

Future<void> seed(AppDatabase db) async {
  final id = await db.addSource(SourcesCompanion.insert(
    type: BackendType.xtream,
    name: 'Home provider',
    url: 'http://x.test',
    username: const Value('u'),
    password: const Value('p'),
    lastSyncedAt: Value(DateTime.now()),
  ));
  const names = [
    'Nordlys News', 'Harbor Sports', 'Fjord One', 'Aurora Kids', 'Cinema North',
    'Polar Docs', 'Metro Music', 'Granite Drama', 'A channel with an extremely '
        'long name that must never overflow the row at any window size',
  ];
  final categories = [
    for (final (kind, name) in [
      (CategoryKind.live, 'News'),
      (CategoryKind.live, 'Sports'),
      (CategoryKind.vod, 'Action'),
      (CategoryKind.vod, 'Drama'),
      (CategoryKind.series, 'Crime'),
    ])
      Category(
          id: '$id:${kind.name}:$name', sourceId: id, name: name, kind: kind),
  ];
  await db.replaceCatalog(
    await db.source(id),
    PlaylistData(
      categories: categories,
      channels: [
        for (final (i, name) in names.indexed)
          PlaylistChannel(
            id: '$id:$i',
            sourceId: id,
            name: name,
            streamUrl: 'http://s.test/$i.ts',
            categoryId: '$id:live:News',
            tvgId: i == 5 ? null : 'tvg$i',
            backendType: BackendType.xtream,
            sortOrder: i,
          ),
      ],
      vod: [
        for (final (i, name) in names.indexed)
          VodItem(
            id: '$id:$i',
            sourceId: id,
            title: name,
            streamUrl: 'http://s.test/$i.mp4',
            categoryId: '$id:vod:Action',
            year: 2020 + i % 6,
            rating: 7.2,
            sortOrder: i,
          ),
      ],
      series: [
        for (final (i, name) in names.indexed)
          SeriesItem(
            id: '$id:$i',
            sourceId: id,
            title: name,
            categoryId: '$id:series:Crime',
            year: 2021,
            rating: 8,
            sortOrder: i,
          ),
      ],
    ),
  );
  final start = DateTime.now().subtract(const Duration(minutes: 40));
  await db.saveEpg([
    for (var c = 0; c < names.length; c++)
      for (var p = 0; p < 6; p++)
        EpgProgram(
          channelId: 'tvg$c',
          title: 'Programme ${p + 1} on channel ${c + 1}',
          description: 'What this programme is about, in a sentence or two.',
          startTime: start.add(Duration(minutes: p * 70 + c * 5)),
          stopTime: start.add(Duration(minutes: (p + 1) * 70 + c * 5)),
        ),
  ]);
  await db.setFavorite('$id:0', true);
}

Future<void> loadFonts() async {
  for (final (family, files) in [
    ('Inter', ['Inter-400', 'Inter-500', 'Inter-600']),
    ('Space Grotesk', ['SpaceGrotesk-500', 'SpaceGrotesk-600']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('assets/fonts/$f.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons');
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final font = File('$flutterRoot/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf');
  if (font.existsSync()) {
    icons.addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await icons.load();
  }
}

void main() {
  // Real time: drift's watchers never finish under the default fake clock.
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  // Frames run as data arrives, as in the app: rows load in several steps.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final shots = Platform.environment['SHOT_DIR'];
  final boundary = GlobalKey();

  Future<void> shot(WidgetTester tester, String name) async {
    if (shots == null) return;
    await tester.runAsync(() async {
      final object = boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await object.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump();
  }

  for (final (label, size) in [
    ('desktop', const Size(1440, 900)),
    ('tablet', const Size(900, 700)),
    ('phone', const Size(420, 800)),
  ]) {
    testWidgets('every tab renders without overflow at $label size',
        (tester) async {
      await tester.runAsync(loadFonts);
      await binding.setSurfaceSize(size);
      addTearDown(() => binding.setSurfaceSize(null));
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() => seed(db));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dioProvider.overrideWithValue(
              Dio()..httpClientAdapter = EpisodesAdapter()),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: onAirTheme(),
              home: const HomeScreen()),
        ),
      ));
      await settle(tester);
      expect(tester.getSize(find.byType(HomeScreen)), size);
      expect(find.textContaining('Programme 1 on channel 1'),
          size.width >= 1100 ? findsWidgets : findsOneWidget);
      await shot(tester, '$label-live');

      await tester.tap(find.byTooltip('Home'));
      await settle(tester);
      expect(find.text('Top movies'), findsOneWidget);
      await shot(tester, '$label-home');

      for (final (tab, name) in [
        ('Movies', 'movies'),
        ('Series', 'series'),
        ('Guide', 'guide'),
        ('Sources', 'sources'),
      ]) {
        await tester.tap(find.text(tab).first);
        await settle(tester);
        await shot(tester, '$label-$name');
      }

      await tester.tap(find.byTooltip('Edit Home provider'));
      await settle(tester);
      expect(find.text('Edit source'), findsOneWidget);
      await shot(tester, '$label-edit');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  testWidgets('dashboard cards open what they recommend', (tester) async {
    await binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => binding.setSurfaceSize(null));
    FakeActiveStream.played.clear();
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() => seed(db));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        dioProvider
            .overrideWithValue(Dio()..httpClientAdapter = EpisodesAdapter()),
        activeStreamProvider.overrideWith(FakeActiveStream.new),
        playerProvider
            .overrideWith((ref) => Completer<IptvPlayer>().future),
      ],
      child: MaterialApp(
        theme: onAirTheme(),
        home: const Scaffold(body: DashboardTab()),
      ),
    ));
    await settle(tester);

    Finder inShelf(String title, Type card) => find.descendant(
        of: find.byKey(ValueKey(title)), matching: find.byType(card));
    Future<void> back() async {
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await settle(tester);
    }

    await tester.tap(find.text('Harbor Sports').first);
    await settle(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    await back();

    await tester.tap(inShelf('Top movies', PosterCard).first);
    await settle(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    await back();

    final series = inShelf('Top series', PosterCard).first;
    await tester.ensureVisible(series);
    await settle(tester);
    await tester.tap(series);
    await settle(tester);
    await tester.tap(find.text('Episode title number 1'));
    await settle(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);

    expect(FakeActiveStream.played,
        ['Harbor Sports', 'Polar Docs',
            'Nordlys News · S1E1  Episode title number 1']);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('home shows history and TMDB lists it can play', (tester) async {
    await tester.runAsync(loadFonts);
    await binding.setSurfaceSize(const Size(1440, 2800));
    addTearDown(() => binding.setSurfaceSize(null));
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await seed(db);
      await db.saveSetting('tmdb_key', 'good');
      await db.markChannelWatched('1:3');
      await db.saveProgress(
        const VodItem(id: '1:ep:9', sourceId: 1, title: 'Crime · S2E3  Heist',
            streamUrl: 'u', categoryId: '', sortOrder: 0),
        const Duration(minutes: 20),
        const Duration(minutes: 50),
      );
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        dioProvider
            .overrideWithValue(Dio()..httpClientAdapter = EpisodesAdapter()),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: onAirTheme(),
          home: const Scaffold(body: DashboardTab()),
        ),
      ),
    ));
    await settle(tester);
    await settle(tester);
    await shot(tester, 'desktop-home-curated');

    Finder posters(String shelf) => find.descendant(
        of: find.byKey(ValueKey(shelf)), matching: find.byType(PosterCard));
    List<String> titles(String shelf) => [
          for (final card in tester.widgetList<PosterCard>(posters(shelf)))
            card.title,
        ];
    expect(titles('Keep watching'), ['Crime · S2E3  Heist']);
    expect(find.descendant(
        of: find.byKey(const ValueKey('Recently watched')),
        matching: find.text('Aurora Kids')), findsOneWidget);
    // Hindi is filtered out, and what the provider lacks never appears.
    expect(titles('Trending movies'), ['Granite Drama', 'Metro Music']);
    expect(titles('Top rated series'), ['Granite Drama', 'Metro Music']);
    expect(find.text('Top movies'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a rejected TMDB key says so', () async {
    final client = TmdbClient(Dio()..httpClientAdapter = EpisodesAdapter());
    await expectLater(
      client.fetch('bad'),
      throwsA(isA<PlaylistException>()
          .having((e) => e.message, 'message', 'TMDB rejected this key')),
    );
  });

  test('provider spellings normalise to the TMDB title', () {
    for (final raw in [
      'EN - The Matrix (1999) [4K]',
      '4K | EN - The Matrix',
      '|EN| The Matrix FHD',
      'The Matrix 1999',
      'THE MATRIX',
      'The Matrix (Multi-Sub)',
    ]) {
      expect(normalizeTitle(raw), 'matrix', reason: raw);
    }
    expect(normalizeTitle('Fast & Furious'), normalizeTitle('Fast and Furious'));
    expect(normalizeTitle('Mission: Impossible'), 'mission impossible');
    expect(normalizeTitle('Amélie'), 'amélie');
    expect(normalizeTitle('2012'), '2012');
  });

  test('matching respects years, order and original titles', () {
    List<String> match(List<CatalogTitle> catalog, List<TmdbTitle> wanted) =>
        matchCatalog((catalog: catalog, wanted: wanted));
    const dune84 = (id: 'old', title: 'EN - Dune (1984)', year: null);
    const dune21 = (id: 'new', title: 'Dune', year: 2021);
    const unknown = (id: 'any', title: 'Heat', year: null);
    const local = (id: 'de', title: 'Das Boot', year: 1981);
    expect(
        match(
          [dune84, dune21, unknown, local],
          [
            (title: 'Heat', original: 'Heat', year: 1995),
            (title: 'Dune', original: 'Dune', year: 2021),
            (title: 'The Boat', original: 'Das Boot', year: 1981),
            (title: 'Missing', original: 'Missing', year: 2000),
          ],
        ),
        ['any', 'new', 'de']);
    // A remake must not stand in for the original.
    expect(match([dune84], [(title: 'Dune', original: 'Dune', year: 2021)]),
        isEmpty);
  });

  test('progress: false starts ignored, finished titles cleared', () {
    const hour = Duration(hours: 1);
    expect(progressAction(const Duration(seconds: 10), hour, false),
        ProgressAction.ignore);
    expect(progressAction(const Duration(minutes: 20), hour, false),
        ProgressAction.save);
    expect(progressAction(const Duration(minutes: 58), hour, false),
        ProgressAction.clear);
    expect(progressAction(Duration.zero, Duration.zero, true),
        ProgressAction.clear);
    expect(progressAction(const Duration(minutes: 5), Duration.zero, false),
        ProgressAction.ignore);
  });

  test('history survives a version 2 database upgrade', () async {
    final dir = Directory.systemTemp.createTempSync('cloud_iptv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/app.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    await seed(db);
    await db.customStatement('DROP TABLE watch_progress');
    await db.customStatement('DROP TABLE recent_channels');
    await db.customStatement('PRAGMA user_version = 2');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.markChannelWatched('1:2');
    expect((await db.watchRecentChannels(5).first).single.name, 'Fjord One');
    expect((await db.allSources()).single.name, 'Home provider');
    expect(await db.watchKeepWatching(5).first, isEmpty);
  });

  test('removing a source removes its history', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    await db.markChannelWatched('1:2');
    await db.saveProgress(
      const VodItem(id: '1:0', sourceId: 1, title: 't', streamUrl: 'u',
          categoryId: 'c', sortOrder: 0),
      const Duration(minutes: 1),
      const Duration(minutes: 9),
    );
    await db.deleteSource(1);
    expect(await db.watchKeepWatching(5).first, isEmpty);
    expect(await db.watchRecentChannels(5).first, isEmpty);
  });

  test('live picks: favourites, then on air, then the rest', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    await db.setFavorite('1:7', true);
    final picks = await db.recommendedChannels(DateTime.now(), 20);
    expect(picks.map((c) => c.id), [
      '1:7', '1:0', // favourites, by name
      '1:1', '1:2', '1:3', '1:4', '1:6', '1:8', // on air, in lineup order
      '1:5', // no guide
    ]);
    expect(await db.recommendedChannels(DateTime.now(), 3), hasLength(3));
  });

  test('top movies rank by rating, unrated last, each title once', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    VodItemsCompanion movie(String id, String category, double? rating) =>
        VodItemsCompanion.insert(
            id: id,
            sourceId: 1,
            title: id,
            streamUrl: 'u',
            categoryId: category,
            rating: Value(rating),
            sortOrder: 0);
    for (final m in [
      movie('low', 'a', 4),
      movie('none', 'a', null),
      movie('best', 'a', 9),
      movie('best', 'b', 9),
    ]) {
      await db.into(db.vodItems).insert(m);
    }
    final top = await db.watchTopVod(20).first;
    expect(top.map((m) => m.id), ['best', 'low', 'none']);
  });

  test('monograms use up to two initials', () {
    expect(monogram('Nordlys News Extra'), 'NN');
    expect(monogram('tv2'), 'T');
    expect(monogram('  '), '?');
  });

  test('previous and next wrap around the playlist', () {
    PlaylistChannel c(String id) => PlaylistChannel(
        id: id,
        sourceId: 1,
        name: id,
        streamUrl: 'u',
        categoryId: 'c',
        backendType: BackendType.m3u,
        sortOrder: 0);
    final list = [c('a'), c('b'), c('c')];
    expect(stepChannel(list, 'c', 1)?.id, 'a');
    expect(stepChannel(list, 'a', -1)?.id, 'c');
    expect(stepChannel(list, 'a', 1)?.id, 'b');
    expect(stepChannel(const [], 'a', 1), isNull);
  });

  test('time labels read naturally', () {
    final now = DateTime(2030, 1, 1, 12);
    expect(timeLeft(now.add(const Duration(minutes: 18)), now), '18 min left');
    expect(timeLeft(now.add(const Duration(minutes: 72)), now),
        '1 h 12 min left');
    expect(syncedAgo(null, now), 'Not synced yet');
    expect(syncedAgo(now.subtract(const Duration(seconds: 5)), now),
        'Synced just now');
    expect(syncedAgo(now.subtract(const Duration(minutes: 1)), now),
        'Synced 1 minute ago');
    expect(syncedAgo(now.subtract(const Duration(hours: 3)), now),
        'Synced 3 hours ago');
    expect(formatPosition(const Duration(minutes: 3, seconds: 7)), '3:07');
    expect(formatPosition(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });

  test('source stats count unique items and channels with a guide', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    final stats = await db.watchSourceStats(1).first;
    expect(stats, (live: 9, movies: 9, series: 9, guide: 8));
    expect(await db.watchCategoryCounts().first, {'1:live:News': 9});
    Future<List<String>> names(CategoryKind kind) async =>
        (await db.watchCategories(kind).first).map((c) => c.name).toList();
    expect(await names(CategoryKind.live), ['News']);
    expect(await names(CategoryKind.vod), ['Action']);
    expect(await names(CategoryKind.series), ['Crime']);
  });
}
