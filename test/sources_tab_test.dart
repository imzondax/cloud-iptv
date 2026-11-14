import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/providers/providers.dart';
import 'package:cloud_iptv/services/database.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/secrets.dart';
import 'package:cloud_iptv/services/sync_service.dart';
import 'package:cloud_iptv/ui/sources_tab.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingBackend implements PlaylistBackend {
  final fetched = <Source>[];

  @override
  Future<PlaylistData?> fetch(Source source,
      {Future<void> Function(PlaylistData live)? onLive}) async {
    fetched.add(source);
    return null;
  }

  @override
  Future<List<EpgProgram>> fetchEpg(
          Source source, Map<String, String> wanted) async =>
      const [];
}

void main() {
  // Real time: drift's watchers never finish under the default fake clock.
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late RecordingBackend backend;
  late int id;

  Future<Source> open(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncServiceProvider.overrideWithValue(SyncService(db, {
          BackendType.m3u: backend,
          BackendType.xtream: backend,
        })),
      ],
      child: const MaterialApp(home: Scaffold(body: SourcesTab())),
    ));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit Provider'));
    await tester.pumpAndSettle();
    return (await tester.runAsync(() => db.source(id)))!;
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<Source> stored(WidgetTester tester) async =>
      (await tester.runAsync(() => db.source(id)))!;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  }

  Future<void> addSource(WidgetTester tester, BackendType type) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      backend = RecordingBackend();
      final xtream = type == BackendType.xtream;
      id = await db.addSource(SourcesCompanion.insert(
        type: type,
        name: 'Provider',
        url: 'http://old.test',
        username: Value(xtream ? 'user' : null),
        password: Value(xtream ? 'pass' : null),
        etag: const Value('"v1"'),
        lastSyncedAt: Value(DateTime.now()),
      ));
    });
  }

  testWidgets('prefills every Xtream field', (tester) async {
    await addSource(tester, BackendType.xtream);
    await open(tester);
    for (final text in ['Provider', 'http://old.test', 'user', 'pass']) {
      expect(find.widgetWithText(TextFormField, text), findsOneWidget);
    }
    await finish(tester);
  });

  testWidgets('a rename keeps the sync state and does not resync',
      (tester) async {
    await addSource(tester, BackendType.m3u);
    final before = await open(tester);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Provider'), 'Renamed');
    await save(tester);

    final after = await stored(tester);
    expect(after.name, 'Renamed');
    expect(after.etag, before.etag);
    expect(after.lastSyncedAt, before.lastSyncedAt);
    expect(backend.fetched, isEmpty);
    await finish(tester);
  });

  testWidgets('new Xtream credentials reach the very next sync', (tester) async {
    await addSource(tester, BackendType.xtream);
    await open(tester);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'pass'), 'new pass');
    await save(tester);

    // In the keychain, not the database.
    expect(backend.fetched.single.password, isNull);
    expect(
        await tester.runAsync(
            () => const Secrets().password(backend.fetched.single)),
        'new pass');
    expect(backend.fetched.single.etag, isNull);
    await finish(tester);
  });

  testWidgets('a new M3U URL drops the old ETag and resyncs', (tester) async {
    await addSource(tester, BackendType.m3u);
    await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'http://old.test'),
        'http://new.test');
    await save(tester);

    expect(backend.fetched.single.url, 'http://new.test');
    expect(backend.fetched.single.etag, isNull);
    await finish(tester);
  });

  testWidgets('an invalid URL is rejected and nothing is saved', (tester) async {
    await addSource(tester, BackendType.m3u);
    await open(tester);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'http://old.test'), 'not a url');
    await save(tester);

    expect(find.text('Enter an http:// or https:// URL'), findsOneWidget);
    expect((await stored(tester)).url, 'http://old.test');
    await finish(tester);
  });

  testWidgets('the source type cannot be changed while editing', (tester) async {
    await addSource(tester, BackendType.m3u);
    await open(tester);
    await tester.tap(find.text('Xtream Codes'));
    await tester.pumpAndSettle();
    expect(find.text('Username'), findsNothing);
    await finish(tester);
  });
}
