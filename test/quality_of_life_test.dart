import 'dart:io';

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/providers/providers.dart';
import 'package:cloud_iptv/services/database.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/tmdb.dart';
import 'package:cloud_iptv/services/updates.dart';
import 'package:cloud_iptv/services/xtream_client.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = PlaylistChannel(
  id: '1:7',
  sourceId: 1,
  name: 'News',
  streamUrl: 'http://x.test:8080/live/user/pass/7.ts',
  categoryId: '1:live:1',
  backendType: BackendType.xtream,
  sortOrder: 0,
  archiveDays: 2,
);

EpgProgram _program(DateTime start, DateTime stop) => EpgProgram(
      channelId: 'news',
      title: 'Show',
      startTime: start,
      stopTime: stop,
    );

VodItem _vod(String id, String category) => VodItem(
      id: id,
      sourceId: 1,
      title: id,
      streamUrl: 'http://x.test/$id.mp4',
      categoryId: category,
      sortOrder: 0,
    );

Future<int> _source(AppDatabase db) => db.addSource(SourcesCompanion.insert(
    type: BackendType.xtream, name: 's', url: 'http://x.test'));

Future<void> _catalog(AppDatabase db, int id) async {
  final source = await db.source(id);
  await db.replaceCatalog(
    source,
    PlaylistData(
      categories: [
        Category(id: 'a', sourceId: id, name: 'A', kind: CategoryKind.vod),
        Category(id: 'b', sourceId: id, name: 'B', kind: CategoryKind.vod),
      ],
      channels: const [],
      vod: [_vod('$id:1', 'a'), _vod('$id:2', 'b')],
      series: const [],
    ),
  );
}

void main() {
  group('catch-up', () {
    final now = DateTime(2026, 11, 7, 20);

    test('needs a finished programme inside the archive', () {
      final ended = _program(now.subtract(const Duration(hours: 2)),
          now.subtract(const Duration(hours: 1)));
      final airing = _program(now.subtract(const Duration(minutes: 5)),
          now.add(const Duration(minutes: 5)));
      final tooOld = _program(now.subtract(const Duration(days: 3)),
          now.subtract(const Duration(days: 3)).add(const Duration(hours: 1)));
      expect(canCatchUp(_channel, ended, now), isTrue);
      expect(canCatchUp(_channel, airing, now), isFalse);
      expect(canCatchUp(_channel, tooOld, now), isFalse);
    });

    test('a channel without an archive has no catch-up', () {
      const channel = PlaylistChannel(
        id: '1:8',
        sourceId: 1,
        name: 'n',
        streamUrl: 'http://x.test/live/u/p/8.ts',
        categoryId: 'c',
        backendType: BackendType.xtream,
        sortOrder: 0,
      );
      final ended = _program(now.subtract(const Duration(hours: 2)),
          now.subtract(const Duration(hours: 1)));
      expect(canCatchUp(channel, ended, now), isFalse);
    });

    test('builds the timeshift address', () {
      final url = catchUpUrl(
          _channel,
          _program(DateTime(2026, 11, 7, 9, 5), DateTime(2026, 11, 7, 10, 35)));
      expect(url,
          'http://x.test:8080/timeshift/user/pass/90/2026-11-07:09-05/7.ts');
    });
  });

  group('updates', () {
    test('compares versions as numbers', () {
      expect(isNewerVersion('v1.10.0', '1.9.0'), isTrue);
      expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
      expect(isNewerVersion('v1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
      expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    });

    test('the app knows its own version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(RegExp(r'^version: ([\d.]+)', multiLine: true)
          .firstMatch(pubspec)![1], appVersion);
    });
  });

  test('a PIN hash matches only the same PIN', () {
    expect(hashPin('1234'), hashPin('1234'));
    expect(hashPin('1234'), isNot(hashPin('1235')));
    expect(hashPin('1234'), isNot(contains('1234')));
  });

  test('artwork searches drop provider tags', () {
    expect(searchableTitle('EN - The Matrix (1999) [4K]'), 'The Matrix');
    expect(searchableTitle('|NO| Kon-Tiki'), 'Kon-Tiki');
  });

  group('database', () {
    late AppDatabase db;
    late int id;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      id = await _source(db);
      await _catalog(db, id);
    });

    tearDown(() => db.close());

    Future<List<String>> shownTop() async =>
        (await db.watchTopVod(10).first).map((v) => v.id).toList();

    test('a hidden category leaves every list, and running queries notice',
        () async {
      final updates = db.watchTopVod(10).map((r) => r.length);
      final seen = <int>[];
      final sub = updates.listen(seen.add);
      await pumpEventQueue();
      await db.setCategoryRule('b', hidden: true, locked: false);
      await pumpEventQueue();
      await sub.cancel();
      expect(seen, [2, 1]);
      expect((await db.watchCategories(CategoryKind.vod).first).map((c) => c.id),
          ['a']);
      expect((await db.watchVod(null, '2').first), isEmpty);
    });

    test('a locked category opens with the session flag and closes again',
        () async {
      await db.setCategoryRule('b', hidden: false, locked: true);
      expect(await shownTop(), ['$id:1']);
      await db.setUnlocked(true);
      expect(await shownTop(), unorderedEquals(['$id:1', '$id:2']));
      await db.setUnlocked(false);
      expect(await shownTop(), ['$id:1']);
    });

    test('hidden stays hidden even when unlocked', () async {
      await db.setCategoryRule('b', hidden: true, locked: false);
      await db.setUnlocked(true);
      expect(await shownTop(), ['$id:1']);
    });

    test('removing the PIN cannot strand a lock', () async {
      await db.setCategoryRule('b', hidden: false, locked: true);
      await db.clearLocks();
      expect(await shownTop(), unorderedEquals(['$id:1', '$id:2']));
    });

    test('Keep watching respects hidden categories', () async {
      await db.saveProgress(_vod('$id:2', 'b'), const Duration(minutes: 5),
          const Duration(minutes: 90));
      expect(await db.watchKeepWatching(5).first, hasLength(1));
      await db.setCategoryRule('b', hidden: true, locked: false);
      expect(await db.watchKeepWatching(5).first, isEmpty);
    });

    test('favorite movies form their own list and survive a resync', () async {
      await db.setFavoriteTitle('$id:2', CategoryKind.vod, true);
      await _catalog(db, id);
      final rows = await db.watchVod(favoritesCategoryId, '').first;
      expect(rows.map((v) => v.id), ['$id:2']);
      await db.setFavoriteTitle('$id:2', CategoryKind.vod, false);
      expect(await db.watchVod(favoritesCategoryId, '').first, isEmpty);
    });

    test('a due reminder fires once, and later ones wait', () async {
      final now = DateTime(2026, 11, 7, 20);
      await db.addReminder(
          '1:7', _program(now, now.add(const Duration(hours: 1))));
      await db.addReminder(
          '1:7',
          _program(now.add(const Duration(hours: 3)),
              now.add(const Duration(hours: 4))));
      expect(await db.takeDueReminders(now), hasLength(1));
      expect(await db.takeDueReminders(now), isEmpty);
      expect(await db.watchReminders().first, hasLength(1));
    });

    test('removing a source removes what hangs off it', () async {
      await db.setFavoriteTitle('$id:1', CategoryKind.vod, true);
      await db.setCategoryRule('$id:vod:1', hidden: true, locked: false);
      final now = DateTime(2026, 11, 7, 20);
      await db.addReminder(
          '$id:7', _program(now, now.add(const Duration(hours: 1))));
      await db.deleteSource(id);
      expect(await db.watchFavoriteTitles(CategoryKind.vod).first, isEmpty);
      expect(await db.watchCategoryRules().first, isEmpty);
      expect(await db.watchReminders().first, isEmpty);
    });
  });

  test('a version 3 database upgrades and keeps its data', () async {
    final dir = Directory.systemTemp.createTempSync('cloud_iptv_migration');
    final file = File('${dir.path}/app.sqlite');
    addTearDown(() => dir.deleteSync(recursive: true));

    var db = AppDatabase(NativeDatabase(file));
    final id = await _source(db);
    await db.saveSetting('volume', '40');
    await db.updateSource(id, const SourcesCompanion(etag: Value('old')));
    await db.customStatement('''
      INSERT INTO channels (id, source_id, name, stream_url, category_id,
        backend_type, sort_order) VALUES ('$id:1', $id, 'n', 'u', 'c', 'xtream', 0)
    ''');
    await db.customStatement('ALTER TABLE channels DROP COLUMN archive_days');
    for (final t in ['favorite_titles', 'category_rules', 'reminders']) {
      await db.customStatement('DROP TABLE $t');
    }
    await db.customStatement('PRAGMA user_version = 3');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.setting('volume'), '40');
    expect((await db.channelById('$id:1'))?.archiveDays, 0);
    expect(await db.watchReminders().first, isEmpty);
    final source = await db.source(id);
    expect(source.etag, isNull);
    expect(source.lastSyncedAt, isNull);
  });

  test('a locked session does not survive a restart', () async {
    final dir = Directory.systemTemp.createTempSync('cloud_iptv_unlock');
    final file = File('${dir.path}/app.sqlite');
    addTearDown(() => dir.deleteSync(recursive: true));

    var db = AppDatabase(NativeDatabase(file));
    await db.setUnlocked(true);
    expect(await db.watchUnlocked().first, isTrue);
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.watchUnlocked().first, isFalse);
  });
}
