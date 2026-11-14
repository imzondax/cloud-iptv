import '../models/models.dart';
import 'database.dart';
import 'playlist_backend.dart';

class SyncService {
  SyncService(this._db, this._backends);

  static const staleAfter = Duration(hours: 6);

  final AppDatabase _db;
  final Map<BackendType, PlaylistBackend> _backends;

  /// Returns a user-safe error message, or null on success. The cached catalog
  /// is only replaced by a successful, non-empty result. [onStep] hears what
  /// it is doing, for the progress line.
  Future<String?> sync(Source source,
      {void Function(String step)? onStep}) async {
    final backend = _backends[source.type]!;
    try {
      onStep?.call('downloading the playlist');
      final data = await backend.fetch(
        source,
        // Later syncs show the old catalog meanwhile, so only a first gains.
        onLive: source.lastSyncedAt != null
            ? null
            : (live) async {
                onStep?.call('saving ${live.channels.length} live channels');
                await _db.addLiveChannels(source, live);
                onStep?.call('downloading movies and series');
              },
      );
      if (data != null) {
        // Expired accounts and error pages often arrive as a valid empty list.
        if (data.isEmpty) {
          throw const PlaylistException('The playlist contains no streams');
        }
        onStep?.call('saving ${data.channels.length} channels, '
            '${data.vod.length} movies and ${data.series.length} series');
        await _db.replaceCatalog(source, data);
      }
    } catch (e) {
      return '${source.name}: ${safeError(e)}';
    }

    // The guide is optional: losing it must not read as a failed playlist.
    try {
      final current = await _db.source(source.id);
      final wanted = await _db.epgChannels(source.id);
      if (wanted.isNotEmpty) {
        onStep?.call('updating the TV guide');
        await _db.saveEpg(await backend.fetchEpg(current, wanted));
      }
      await _db.pruneEpg(DateTime.now().subtract(const Duration(days: 1)));
    } catch (e) {
      await _db.markSynced(source.id);
      return '${source.name}: guide not updated. ${safeError(e)}';
    }
    await _db.markSynced(source.id);
    return null;
  }

  bool isStale(Source source, DateTime now) =>
      source.lastSyncedAt == null ||
      now.difference(source.lastSyncedAt!) >= staleAfter;
}
