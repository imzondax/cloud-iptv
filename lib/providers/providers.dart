import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../player/iptv_player.dart';
import '../services/database.dart';
import '../services/m3u_parser.dart';
import '../services/playlist_backend.dart';
import '../services/sync_service.dart';
import '../services/tmdb.dart';
import '../services/xtream_client.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final dioProvider = Provider<Dio>((ref) => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 2),
    )));

final xtreamBackendProvider =
    Provider((ref) => XtreamBackend(ref.watch(dioProvider)));

final syncServiceProvider = Provider((ref) => SyncService(
      ref.watch(databaseProvider),
      <BackendType, PlaylistBackend>{
        BackendType.m3u: M3uBackend(ref.watch(dioProvider)),
        BackendType.xtream: ref.watch(xtreamBackendProvider),
      },
    ));

// Playlist state

/// [issues] holds the last problem per source id, until its next sync.
typedef SyncState = ({bool running, String? error, Map<int, String> issues});

final syncProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);

class SyncController extends Notifier<SyncState> {
  @override
  SyncState build() => (running: false, error: null, issues: const {});

  Future<void> syncAll({bool onlyStale = false}) async {
    if (state.running) return;
    final issues = {...state.issues};
    state = (running: true, error: null, issues: issues);
    final service = ref.read(syncServiceProvider);
    final now = DateTime.now();
    String? error;
    for (final source in await ref.read(databaseProvider).allSources()) {
      if (onlyStale && !service.isStale(source, now)) continue;
      final issue = await service.sync(source);
      if (issue == null) {
        issues.remove(source.id);
      } else {
        issues[source.id] = error = issue;
      }
    }
    state = (running: false, error: error, issues: issues);
  }
}

final sourcesProvider =
    StreamProvider((ref) => ref.watch(databaseProvider).watchSources());

final categoriesProvider = StreamProvider.family<List<Category>, CategoryKind>(
    (ref, kind) => ref.watch(databaseProvider).watchCategories(kind));

typedef BrowseQuery = ({CategoryKind kind, String? categoryId, String search});

/// Yields [PlaylistChannel], [VodItem] or [SeriesItem] rows, per query kind.
final browseProvider = StreamProvider.autoDispose
    .family<List<Object>, BrowseQuery>((ref, q) {
  final db = ref.watch(databaseProvider);
  return switch (q.kind) {
    CategoryKind.live => db.watchChannels(q.categoryId, q.search),
    CategoryKind.vod => db.watchVod(q.categoryId, q.search),
    CategoryKind.series => db.watchSeries(q.categoryId, q.search),
  };
});

final categoryCountsProvider = StreamProvider(
    (ref) => ref.watch(databaseProvider).watchCategoryCounts());

final sourceStatsProvider = StreamProvider.autoDispose.family<SourceStats, int>(
    (ref, id) => ref.watch(databaseProvider).watchSourceStats(id));

final favoriteIdsProvider =
    StreamProvider((ref) => ref.watch(databaseProvider).watchFavoriteIds());

final episodesProvider = FutureProvider.autoDispose
    .family<List<Episode>, SeriesItem>((ref, series) async {
  final source = await ref.read(databaseProvider).source(series.sourceId);
  return ref.read(xtreamBackendProvider).fetchEpisodes(source, series);
});

// EPG

/// Ticks each minute, so anything showing "now" stays true.
final minuteProvider = StreamProvider<int>(
    (ref) => Stream.periodic(const Duration(minutes: 1), (i) => i));

typedef Schedule = ({EpgProgram? now, List<EpgProgram> next});

/// What is on and up next, from the local guide only: this feeds list rows, so
/// it must never reach the network.
final scheduleProvider =
    FutureProvider.autoDispose.family<Schedule, String>((ref, key) async {
  ref.watch(minuteProvider);
  final now = DateTime.now();
  final programs = await ref
      .watch(databaseProvider)
      .programs(key, now, now.add(const Duration(hours: 12)));
  final current =
      programs.where((p) => !p.startTime.isAfter(now)).firstOrNull;
  return (
    now: current,
    next: programs.where((p) => p.startTime.isAfter(now)).toList(),
  );
});

const _shelfSize = 20;

final keepWatchingProvider = StreamProvider(
    (ref) => ref.watch(databaseProvider).watchKeepWatching(_shelfSize));

final recentChannelsProvider = StreamProvider(
    (ref) => ref.watch(databaseProvider).watchRecentChannels(_shelfSize));

final tmdbKeyProvider =
    AsyncNotifierProvider<TmdbKey, String?>(TmdbKey.new);

class TmdbKey extends AsyncNotifier<String?> {
  @override
  Future<String?> build() => ref.read(databaseProvider).setting(_tmdbKey);

  Future<void> set(String key) async {
    final db = ref.read(databaseProvider);
    await db.saveSetting(_tmdbKey, key);
    await db.saveSetting(_tmdbCache, '');
    state = AsyncData(key.isEmpty ? null : key);
  }
}

const _tmdbKey = 'tmdb_key';
const _tmdbCache = 'tmdb_cache';
const _tmdbCacheAt = 'tmdb_cache_at';
const _tmdbMaxAge = Duration(hours: 24);

/// TMDB's lists, fetched at most daily, and kept when it cannot be reached.
Future<List<TmdbList>> _tmdbLists(Ref ref, String key) async {
  final db = ref.read(databaseProvider);
  final cached = await db.setting(_tmdbCache);
  final at = DateTime.tryParse(await db.setting(_tmdbCacheAt) ?? '');
  final hasCache = cached != null && cached.isNotEmpty;
  final fresh =
      at != null && DateTime.now().difference(at) < _tmdbMaxAge;
  if (hasCache && fresh) return decodeTmdbLists(cached);
  try {
    final lists = await TmdbClient(ref.read(dioProvider)).fetch(key);
    await db.saveSetting(_tmdbCache, encodeTmdbLists(lists));
    await db.saveSetting(_tmdbCacheAt, DateTime.now().toIso8601String());
    return lists;
  } catch (_) {
    if (hasCache) return decodeTmdbLists(cached);
    rethrow;
  }
}

typedef CuratedShelf = ({String name, List<Object> items});

/// TMDB's lists, narrowed to what the user's providers can actually play.
final curatedShelvesProvider = FutureProvider<List<CuratedShelf>>((ref) async {
  ref.watch(sourcesProvider);
  final key = await ref.watch(tmdbKeyProvider.future);
  if (key == null || key.isEmpty) return const [];
  final db = ref.read(databaseProvider);
  final lists = await _tmdbLists(ref, key);
  final catalogs = {
    for (final kind in [CategoryKind.vod, CategoryKind.series])
      kind: await db.catalogTitles(kind),
  };
  final shelves = <CuratedShelf>[];
  for (final list in lists) {
    final ids = await compute(
        matchCatalog, (catalog: catalogs[list.kind]!, wanted: list.titles));
    final top = ids.take(_shelfSize).toList();
    final List<Object> items = list.kind == CategoryKind.series
        ? await db.seriesByIds(top)
        : await db.vodByIds(top);
    if (items.isNotEmpty) shelves.add((name: list.name, items: items));
  }
  return shelves;
});

final recommendedChannelsProvider = FutureProvider((ref) {
  // What is on air shifts with the clock, a sync and new favourites.
  ref.watch(minuteProvider);
  ref.watch(sourcesProvider);
  ref.watch(favoriteIdsProvider);
  return ref
      .watch(databaseProvider)
      .recommendedChannels(DateTime.now(), _shelfSize);
});

final topMoviesProvider = StreamProvider(
    (ref) => ref.watch(databaseProvider).watchTopVod(_shelfSize));

final topSeriesProvider = StreamProvider(
    (ref) => ref.watch(databaseProvider).watchTopSeries(_shelfSize));

typedef EpgWindow = ({String key, DateTime from, DateTime to});

/// One guide row. Rows are cached by key while visible.
final epgRowProvider = FutureProvider.autoDispose
    .family<List<EpgProgram>, EpgWindow>((ref, w) =>
        ref.watch(databaseProvider).programs(w.key, w.from, w.to));

/// What is on now. Falls back to Xtream's JSON EPG when the guide has no rows.
final currentProgramProvider = FutureProvider.autoDispose
    .family<EpgProgram?, PlaylistChannel>((ref, channel) async {
  final db = ref.read(databaseProvider);
  final now = DateTime.now();
  EpgProgram? current(List<EpgProgram> list) {
    final program = list
        .where((p) => p.startTime.isBefore(now) && p.stopTime.isAfter(now))
        .firstOrNull;
    if (program != null) {
      final timer = Timer(program.stopTime.difference(now), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
    }
    return program;
  }

  final cached = await db.programs(channel.epgKey, now, now);
  if (cached.isNotEmpty || channel.backendType != BackendType.xtream) {
    return current(cached);
  }
  final fetched = await ref
      .read(xtreamBackendProvider)
      .fetchShortEpg(await db.source(channel.sourceId), channel);
  await db.saveEpg(fetched);
  return current(fetched);
});

// Playback

const _hwdecKey = 'hardware_acceleration';

final hardwareAccelerationProvider =
    AsyncNotifierProvider<HardwareAcceleration, bool>(HardwareAcceleration.new);

class HardwareAcceleration extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      await ref.read(databaseProvider).setting(_hwdecKey) != 'false';

  Future<void> set(bool enabled) async {
    state = AsyncData(enabled);
    await ref.read(databaseProvider).saveSetting(_hwdecKey, '$enabled');
    await (await ref.read(playerProvider.future))
        .setHardwareAcceleration(enabled);
  }
}

final bufferProfileProvider =
    AsyncNotifierProvider<BufferSetting, BufferProfile>(BufferSetting.new);

class BufferSetting extends AsyncNotifier<BufferProfile> {
  static const _key = 'buffer_profile';

  @override
  Future<BufferProfile> build() async {
    final saved = await ref.read(databaseProvider).setting(_key);
    return BufferProfile.values.asNameMap()[saved] ?? BufferProfile.medium;
  }

  Future<void> set(BufferProfile profile) async {
    state = AsyncData(profile);
    await ref.read(databaseProvider).saveSetting(_key, profile.name);
    await (await ref.read(playerProvider.future)).setBufferProfile(profile);
  }
}

final playerProvider = FutureProvider<IptvPlayer>((ref) async {
  final enabled = await ref.read(hardwareAccelerationProvider.future);
  final buffer = await ref.read(bufferProfileProvider.future);
  final player = IptvPlayer(hardwareAcceleration: enabled, buffer: buffer);
  ref.onDispose(player.dispose);
  return player;
});

final activeStreamProvider =
    NotifierProvider<ActiveStream, NowPlaying?>(ActiveStream.new);

class NowPlaying {
  const NowPlaying(this.title, {this.channel, this.playlist = const []});

  final String title;
  final PlaylistChannel? channel;

  /// The channels previous/next and the channel list move through.
  final List<PlaylistChannel> playlist;
}

/// The next channel, wrapping at both ends.
PlaylistChannel? stepChannel(
    List<PlaylistChannel> playlist, String? currentId, int delta) {
  if (playlist.isEmpty) return null;
  final index = playlist.indexWhere((c) => c.id == currentId);
  return playlist[(index + delta) % playlist.length];
}

enum ProgressAction { save, clear, ignore }

/// Under 30s is a false start, and the last 5% is the credits: those count as
/// finished, or the title would linger in Keep watching.
ProgressAction progressAction(
    Duration position, Duration duration, bool completed) {
  if (completed) return ProgressAction.clear;
  if (duration <= Duration.zero) return ProgressAction.ignore;
  if (position >= duration * 0.95) return ProgressAction.clear;
  if (position < const Duration(seconds: 30)) return ProgressAction.ignore;
  return ProgressAction.save;
}

/// What is playing, and the one place streams get switched.
class ActiveStream extends Notifier<NowPlaying?> {
  static const _saveEvery = Duration(seconds: 15);

  /// Long enough that channel surfing does not fill the history.
  static const _countsAsWatched = Duration(seconds: 10);

  Timer? _saver;
  Timer? _recent;
  VodItem? _vod;

  @override
  NowPlaying? build() {
    ref.onDispose(_stopTracking);
    return null;
  }

  void _stopTracking() {
    _saver?.cancel();
    _recent?.cancel();
    _vod = null;
  }

  Future<void> _saveProgress(IptvPlayer player) async {
    final item = _vod;
    if (item == null) return;
    final state = player.player.state;
    final db = ref.read(databaseProvider);
    switch (progressAction(state.position, state.duration, state.completed)) {
      case ProgressAction.save:
        await db.saveProgress(item, state.position, state.duration);
      case ProgressAction.clear:
        await db.clearProgress(item.id);
      case ProgressAction.ignore:
        break;
    }
  }

  Future<void> playChannel(PlaylistChannel channel,
      {List<PlaylistChannel>? playlist}) async {
    state = NowPlaying(channel.name,
        channel: channel, playlist: playlist ?? state?.playlist ?? [channel]);
    _stopTracking();
    final db = ref.read(databaseProvider);
    _recent = Timer(
        _countsAsWatched, () => db.markChannelWatched(channel.id));
    final fallbacks = await db.fallbackUrls(channel.id);
    final player = await ref.read(playerProvider.future);
    await player.open([channel.streamUrl, ...fallbacks], live: true);
  }

  Future<void> step(int delta) async {
    final current = state;
    final next =
        stepChannel(current?.playlist ?? [], current?.channel?.id, delta);
    if (next != null) await playChannel(next);
  }

  Future<void> playVod(VodItem item) async {
    state = NowPlaying(item.title);
    _stopTracking();
    final start = await ref.read(databaseProvider).progress(item.id);
    final player = await ref.read(playerProvider.future);
    await player.open([item.streamUrl], live: false, start: start);
    _vod = item;
    _saver = Timer.periodic(_saveEvery, (_) => _saveProgress(player));
  }

  Future<void> stop() async {
    state = null;
    final player = await ref.read(playerProvider.future);
    await _saveProgress(player);
    _stopTracking();
    await player.stop();
  }
}
