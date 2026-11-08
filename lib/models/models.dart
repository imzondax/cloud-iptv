/// Entities shared by every backend. These are also the drift row classes, so
/// there is no mapping layer between parser output and the database.
library;

enum BackendType { m3u, xtream }

enum CategoryKind { live, vod, series }

class Source {
  const Source({
    required this.id,
    required this.type,
    required this.name,
    required this.url,
    this.username,
    this.password,
    this.epgUrl,
    this.etag,
    this.lastSyncedAt,
  });

  final int id;
  final BackendType type;
  final String name;
  final String url;
  final String? username;
  final String? password;
  final String? epgUrl;

  /// Validator from the last M3U download, used for conditional GETs.
  final String? etag;
  final DateTime? lastSyncedAt;
}

class Category {
  const Category({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.kind,
  });

  final String id;
  final int sourceId;
  final String name;
  final CategoryKind kind;
}

class PlaylistChannel {
  const PlaylistChannel({
    required this.id,
    required this.sourceId,
    required this.name,
    this.logoUrl,
    required this.streamUrl,
    required this.categoryId,
    this.tvgId,
    required this.backendType,
    required this.sortOrder,
    this.archiveDays = 0,
  });

  final String id;
  final int sourceId;
  final String name;
  final String? logoUrl;
  final String streamUrl;
  final String categoryId;
  final String? tvgId;
  final BackendType backendType;
  final int sortOrder;

  /// How far back the provider keeps this channel, for catch-up.
  final int archiveDays;

  /// The key this channel's programmes are stored under.
  String get epgKey => tvgId ?? id;
}

class VodItem {
  const VodItem({
    required this.id,
    required this.sourceId,
    required this.title,
    this.posterUrl,
    required this.streamUrl,
    required this.categoryId,
    this.year,
    this.rating,
    required this.sortOrder,
  });

  final String id;
  final int sourceId;
  final String title;
  final String? posterUrl;
  final String streamUrl;
  final String categoryId;
  final int? year;
  final double? rating;
  final int sortOrder;
}

/// A series listing. Its episodes are fetched on demand as [VodItem]s.
class SeriesItem {
  const SeriesItem({
    required this.id,
    required this.sourceId,
    required this.title,
    this.posterUrl,
    required this.categoryId,
    this.year,
    this.rating,
    required this.sortOrder,
    this.director,
    this.genre,
  });

  final String id;
  final int sourceId;
  final String title;
  final String? posterUrl;
  final String categoryId;
  final int? year;
  final double? rating;
  final int sortOrder;

  /// As the panel sends them, such as `Drama, Crime`. Only Xtream has these.
  final String? director;
  final String? genre;
}

/// One playable episode of a [SeriesItem].
class Episode {
  const Episode({
    required this.item,
    required this.season,
    required this.number,
    required this.name,
    this.duration,
  });

  final VodItem item;
  final int season;
  final int number;
  final String name;

  /// As the panel reports it, such as `00:42:10`.
  final String? duration;
}

class EpgProgram {
  const EpgProgram({
    required this.channelId,
    required this.title,
    required this.startTime,
    required this.stopTime,
    this.description,
  });

  /// `tvg-id` of the channel, see [PlaylistChannel.epgKey].
  final String channelId;
  final String title;
  final DateTime startTime;
  final DateTime stopTime;
  final String? description;
}

class StreamFallback {
  const StreamFallback({
    required this.channelId,
    required this.url,
    required this.priority,
  });

  final String channelId;
  final String url;
  final int priority;
}
