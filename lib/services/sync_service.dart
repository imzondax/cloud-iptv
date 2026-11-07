import '../models/models.dart';
import 'database.dart';
import 'playlist_backend.dart';

class SyncService {
  SyncService(this._db, this._backends);

  static const staleAfter = Duration(hours: 6);

  final AppDatabase _db;
  final Map<BackendType, PlaylistBackend> _backends;

  /// Returns a user-safe error message, or null on success. The cached catalog
  /// is only replaced by a successful, non-empty result.
  Future<String?> sync(Source source) async {
    final backend = _backends[source.type]!;
    try {
      final data = await backend.fetch(source);
      if (data != null) {
        // Expired accounts and error pages often arrive as a valid empty list.
        if (data.isEmpty) {
          throw const PlaylistException('The playlist contains no streams');
        }
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
