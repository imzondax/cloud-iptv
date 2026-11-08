import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'playlist_backend.dart';
import 'tmdb.dart' show yearInTitle;

/// Thin wrapper over `player_api.php`. Responses stay raw strings here so
/// decoding and mapping happen in [parseXtreamCatalog] off the main isolate.
class XtreamClient {
  XtreamClient(this._dio, String url, this.username, this.password)
      : baseUrl = normalizeBaseUrl(url);

  final Dio _dio;
  final String baseUrl;
  final String username;
  final String password;

  /// Users often paste the full API URL rather than the server root.
  static String normalizeBaseUrl(String url) => url
      .trim()
      .replaceFirst(RegExp(r'/player_api\.php.*$'), '')
      .replaceFirst(RegExp(r'/+$'), '');

  Future<String> _get(String? action, [Map<String, Object?> extra = const {}]) async {
    final response = await _dio.get<String>(
      '$baseUrl/player_api.php',
      queryParameters: {
        'username': username,
        'password': password,
        'action': ?action,
        ...extra,
      },
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  Future<void> authenticate() async {
    final body = jsonDecode(await _get(null));
    final info = body is Map ? body['user_info'] : null;
    if (info is! Map || info['auth']?.toString() != '1') {
      throw const PlaylistException('Wrong Xtream username or password');
    }
  }

  Future<String> liveCategories() => _get('get_live_categories');
  Future<String> vodCategories() => _get('get_vod_categories');
  Future<String> seriesCategories() => _get('get_series_categories');
  Future<String> liveStreams() => _get('get_live_streams');
  Future<String> vodStreams() => _get('get_vod_streams');
  Future<String> seriesList() => _get('get_series');

  Future<String> seriesInfo(String seriesId) =>
      _get('get_series_info', {'series_id': seriesId});

  Future<String> shortEpg(String streamId, {int limit = 20}) =>
      _get('get_short_epg', {'stream_id': streamId, 'limit': limit});

  Future<String> epgTable(String streamId) =>
      _get('get_simple_data_table', {'stream_id': streamId});

  String get xmltvUrl => Uri.parse('$baseUrl/xmltv.php').replace(
      queryParameters: {'username': username, 'password': password}).toString();
}

class XtreamBackend implements PlaylistBackend {
  XtreamBackend(this._dio);
  final Dio _dio;

  XtreamClient _client(Source s) =>
      XtreamClient(_dio, s.url, s.username ?? '', s.password ?? '');

  @override
  Future<PlaylistData?> fetch(Source source) async {
    final client = _client(source);
    await client.authenticate();
    final bodies = await Future.wait([
      client.liveCategories(),
      client.vodCategories(),
      client.seriesCategories(),
      client.liveStreams(),
      client.vodStreams(),
      client.seriesList(),
    ]);
    return compute(
      parseXtreamCatalog,
      XtreamCatalogJob(
        sourceId: source.id,
        baseUrl: client.baseUrl,
        username: client.username,
        password: client.password,
        liveCategories: bodies[0],
        vodCategories: bodies[1],
        seriesCategories: bodies[2],
        live: bodies[3],
        vod: bodies[4],
        series: bodies[5],
      ),
    );
  }

  /// Many panels disable xmltv.php (a 404, or an HTML page), so the per-channel
  /// JSON API backs it up.
  @override
  Future<List<EpgProgram>> fetchEpg(
      Source source, Map<String, String> wanted) async {
    final client = _client(source);
    try {
      final programs =
          await fetchXmltv(_dio, client.xmltvUrl, wanted.keys.toSet());
      if (programs.isNotEmpty) return programs;
    } on Exception {
      // Fall through to the JSON API.
    }
    return _fetchJsonEpg(client, wanted);
  }

  // shortcut: only the first 1000 guide channels are fetched this way, to stay
  // polite to the panel. Prioritise favourites if that proves too few.
  static const _jsonEpgChannelLimit = 1000;
  static const _jsonEpgConcurrency = 5;

  Future<List<EpgProgram>> _fetchJsonEpg(
      XtreamClient client, Map<String, String> wanted) async {
    final entries = wanted.entries.take(_jsonEpgChannelLimit).toList();
    final programs = <EpgProgram>[];
    Exception? lastError;
    var succeeded = 0;
    for (var i = 0; i < entries.length; i += _jsonEpgConcurrency) {
      await Future.wait(
          entries.skip(i).take(_jsonEpgConcurrency).map((entry) async {
        try {
          final body = await client.epgTable(rawId(entry.value));
          programs.addAll(parseShortEpg(body, entry.key));
          succeeded++;
        } on Exception catch (e) {
          lastError = e; // One bad channel must not cost the whole guide.
        }
      }));
    }
    if (succeeded == 0 && lastError != null) throw lastError!;
    return programs;
  }

  /// JSON EPG chunk for one channel, for servers without a usable xmltv.php.
  Future<List<EpgProgram>> fetchShortEpg(
      Source source, PlaylistChannel channel) async {
    final body = await _client(source).shortEpg(rawId(channel.id));
    return parseShortEpg(body, channel.epgKey);
  }

  Future<List<Episode>> fetchEpisodes(Source source, SeriesItem series) async {
    final client = _client(source);
    final body = await client.seriesInfo(rawId(series.id));
    return parseEpisodes(
        body, series, client.baseUrl, client.username, client.password);
  }
}

/// Strips the `<sourceId>:` prefix from a stored id.
String rawId(String id) => id.substring(id.indexOf(':') + 1);

class XtreamCatalogJob {
  const XtreamCatalogJob({
    required this.sourceId,
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.liveCategories,
    required this.vodCategories,
    required this.seriesCategories,
    required this.live,
    required this.vod,
    required this.series,
  });

  final int sourceId;
  final String baseUrl, username, password;
  final String liveCategories, vodCategories, seriesCategories;
  final String live, vod, series;
}

/// Isolate entry point. Xtream panels disagree on types (ids as int or string,
/// numbers as "", `[]` for empty objects), hence the lenient readers below.
PlaylistData parseXtreamCatalog(XtreamCatalogJob job) {
  final src = job.sourceId;
  final categories = <Category>[];

  final placed = <String>{};

  /// The categories to file an item under, once each. Panels repeat an item
  /// per category, list them all in `category_ids`, or do both.
  List<String> placements(Map item, String id, CategoryKind kind) {
    final many = item['category_ids'];
    final raw = {
      _str(item['category_id']),
      if (many is List) ...many.map(_str),
    }.nonNulls;
    return (raw.isEmpty ? const ['none'] : raw)
        .map((c) => '$src:${kind.name}:$c')
        .where((c) => placed.add('$id|$c'))
        .toList();
  }

  void addCategories(String body, CategoryKind kind) {
    for (final c in _list(body)) {
      final id = _str(c['category_id']);
      if (id == null) continue;
      categories.add(Category(
        id: '$src:${kind.name}:$id',
        sourceId: src,
        name: _str(c['category_name']) ?? 'Unnamed',
        kind: kind,
      ));
    }
  }

  addCategories(job.liveCategories, CategoryKind.live);
  addCategories(job.vodCategories, CategoryKind.vod);
  addCategories(job.seriesCategories, CategoryKind.series);

  final user = Uri.encodeComponent(job.username);
  final pass = Uri.encodeComponent(job.password);

  final channels = <PlaylistChannel>[];
  for (final s in _list(job.live)) {
    final id = _str(s['stream_id']);
    if (id == null) continue;
    for (final categoryId in placements(s, id, CategoryKind.live)) {
      channels.add(PlaylistChannel(
        id: '$src:$id',
        sourceId: src,
        name: _str(s['name']) ?? 'Unnamed',
        logoUrl: _str(s['stream_icon']),
        streamUrl: '${job.baseUrl}/live/$user/$pass/$id.ts',
        categoryId: categoryId,
        tvgId: _str(s['epg_channel_id']),
        backendType: BackendType.xtream,
        sortOrder: channels.length,
        archiveDays: _str(s['tv_archive']) == '1'
            ? int.tryParse(_str(s['tv_archive_duration']) ?? '') ?? 0
            : 0,
      ));
    }
  }

  final vod = <VodItem>[];
  for (final s in _list(job.vod)) {
    final id = _str(s['stream_id']);
    if (id == null) continue;
    final ext = _str(s['container_extension']) ?? 'mp4';
    for (final categoryId in placements(s, id, CategoryKind.vod)) {
      vod.add(VodItem(
        id: '$src:$id',
        sourceId: src,
        title: _str(s['name']) ?? 'Unnamed',
        posterUrl: _str(s['stream_icon']),
        streamUrl: '${job.baseUrl}/movie/$user/$pass/$id.$ext',
        categoryId: categoryId,
        year: _year(_str(s['year']) ??
                _str(s['releaseDate']) ??
                _str(s['releasedate'])) ??
            yearInTitle(_str(s['name']) ?? ''),
        rating: _double(s['rating']),
        sortOrder: vod.length,
      ));
    }
  }

  final series = <SeriesItem>[];
  for (final s in _list(job.series)) {
    final id = _str(s['series_id']);
    if (id == null) continue;
    for (final categoryId in placements(s, id, CategoryKind.series)) {
      series.add(SeriesItem(
        id: '$src:$id',
        sourceId: src,
        title: _str(s['name']) ?? 'Unnamed',
        posterUrl: _str(s['cover']),
        categoryId: categoryId,
        year: _year(
            _str(s['year']) ?? _str(s['releaseDate']) ?? _str(s['releasedate'])),
        rating: _double(s['rating']),
        sortOrder: series.length,
        director: _str(s['director']),
        genre: _str(s['genre']),
      ));
    }
  }

  // Items pointing at unlisted categories would otherwise be unreachable.
  final known = categories.map((c) => c.id).toSet();
  void addMissing(Iterable<String> ids, CategoryKind kind) {
    for (final id in ids) {
      if (known.add(id)) {
        categories.add(
            Category(id: id, sourceId: src, name: 'Other', kind: kind));
      }
    }
  }

  addMissing(channels.map((c) => c.categoryId), CategoryKind.live);
  addMissing(vod.map((v) => v.categoryId), CategoryKind.vod);
  addMissing(series.map((s) => s.categoryId), CategoryKind.series);

  return PlaylistData(
    categories: categories,
    channels: channels,
    vod: vod,
    series: series,
    fallbacks: fallbacksFor(channels),
  );
}

List<EpgProgram> parseShortEpg(String body, String channelKey) {
  final json = jsonDecode(body);
  final listings = json is Map ? json['epg_listings'] : null;
  if (listings is! List) return [];
  final out = <EpgProgram>[];
  for (final e in listings.whereType<Map>()) {
    final start = int.tryParse(_str(e['start_timestamp']) ?? '');
    final stop = int.tryParse(_str(e['stop_timestamp']) ?? '');
    if (start == null || stop == null) continue;
    out.add(EpgProgram(
      channelId: channelKey,
      title: _base64(e['title']) ?? 'Unknown',
      startTime: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
      stopTime: DateTime.fromMillisecondsSinceEpoch(stop * 1000, isUtc: true),
      description: _base64(e['description']),
    ));
  }
  return out;
}

/// Whether [program] can be replayed from the provider's archive.
bool canCatchUp(PlaylistChannel channel, EpgProgram program, DateTime now) =>
    channel.archiveDays > 0 &&
    !program.stopTime.isAfter(now) &&
    program.startTime
        .isAfter(now.subtract(Duration(days: channel.archiveDays)));

/// The archive URL for [program].
// shortcut: uses this device's time zone, but panels read the time in their
// own. If replays start at the wrong moment, use server_info.timezone instead.
String? catchUpUrl(PlaylistChannel channel, EpgProgram program) {
  final live = RegExp(r'^(.*)/live/([^/]+)/([^/]+)/(\d+)\.\w+$')
      .firstMatch(channel.streamUrl);
  if (live == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  final t = program.startTime.toLocal();
  final start =
      '${t.year}-${two(t.month)}-${two(t.day)}:${two(t.hour)}-${two(t.minute)}';
  final minutes = program.stopTime.difference(program.startTime).inMinutes;
  return '${live[1]}/timeshift/${live[2]}/${live[3]}/$minutes/$start/${live[4]}.ts';
}

List<Episode> parseEpisodes(String body, SeriesItem series, String baseUrl,
    String username, String password) {
  final json = jsonDecode(body);
  final episodes = json is Map ? json['episodes'] : null;
  // A map keyed by season number, or a list of seasons on some panels.
  final seasons = switch (episodes) {
    Map m => m.values,
    List l => l,
    _ => const [],
  };
  final user = Uri.encodeComponent(username);
  final pass = Uri.encodeComponent(password);
  final out = <Episode>[];
  for (final season in seasons.whereType<List>()) {
    for (final e in season.whereType<Map>()) {
      final id = _str(e['id']);
      if (id == null) continue;
      final ext = _str(e['container_extension']) ?? 'mp4';
      final label = 'S${_str(e['season']) ?? '?'}E${_str(e['episode_num']) ?? '?'}';
      final title = _str(e['title']);
      final number = int.tryParse(_str(e['episode_num']) ?? '') ?? out.length + 1;
      final info = e['info'];
      out.add(Episode(
        season: int.tryParse(_str(e['season']) ?? '') ?? 1,
        number: number,
        name: title ?? 'Episode $number',
        duration: info is Map ? _str(info['duration']) : null,
        item: VodItem(
          id: '${series.sourceId}:ep:$id',
          sourceId: series.sourceId,
          title:
              '${series.title} · ${title == null ? label : '$label  $title'}',
          posterUrl: series.posterUrl,
          streamUrl: '$baseUrl/series/$user/$pass/$id.$ext',
          categoryId: series.categoryId,
          sortOrder: out.length,
        ),
      ));
    }
  }
  return out;
}

Iterable<Map> _list(String body) {
  final json = jsonDecode(body);
  return json is List ? json.whereType<Map>() : const [];
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

double? _double(Object? v) => double.tryParse(_str(v) ?? '');

int? _year(Object? v) {
  final match = RegExp(r'\b(19|20)\d\d\b').firstMatch(_str(v) ?? '');
  return match == null ? null : int.parse(match[0]!);
}

String? _base64(Object? v) {
  final s = _str(v);
  if (s == null) return null;
  try {
    return utf8.decode(base64.decode(s), allowMalformed: true);
  } on FormatException {
    return s;
  }
}
