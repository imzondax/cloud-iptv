import 'dart:convert';
import 'dart:io';

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

  Map<String, Object?> _query(String? action, Map<String, Object?> extra) => {
        'username': username,
        'password': password,
        'action': ?action,
        ...extra,
      };

  Future<String> _get(String? action, [Map<String, Object?> extra = const {}]) async {
    final response = await _dio.get<String>(
      '$baseUrl/player_api.php',
      queryParameters: _query(action, extra),
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  /// Saves one list to [path], so a big catalog never sits in memory here.
  Future<void> download(String action, String path, CancelToken cancel) =>
      _dio.download('$baseUrl/player_api.php', path,
          queryParameters: _query(action, const {}), cancelToken: cancel);

  /// Checks the login, and returns the stream formats the panel allows.
  Future<List<String>> authenticate() async {
    final body = jsonDecode(await _get(null));
    final info = body is Map ? body['user_info'] : null;
    if (info is! Map || info['auth']?.toString() != '1') {
      throw const PlaylistException('Wrong Xtream username or password');
    }
    final formats = info['allowed_output_formats'];
    return formats is List ? [for (final f in formats) '$f'] : const [];
  }

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
  /// [password] looks a source's password up, in the keychain in the app.
  XtreamBackend(this._dio, {Future<String?> Function(Source)? password})
      : _password = password ?? ((s) async => s.password);
  final Dio _dio;
  final Future<String?> Function(Source) _password;

  Future<XtreamClient> _client(Source s) async => XtreamClient(
      _dio, s.url, s.username ?? '', await _password(s) ?? '');

  /// Live channels are parsed and handed to [onLive] as soon as they arrive,
  /// as the movie and series lists are often far larger.
  @override
  Future<PlaylistData?> fetch(Source source,
      {Future<void> Function(PlaylistData live)? onLive}) async {
    final client = await _client(source);
    final formats = await client.authenticate();
    // Some panels refuse .ts and only serve HLS.
    final liveExt = formats.isEmpty || formats.contains('ts') ? 'ts' : 'm3u8';
    final dir = await Directory.systemTemp.createTemp('cloud_iptv_xtream');
    final cancel = CancelToken();
    Future<Map<String, String>> download(List<String> actions) async {
      final files = {
        for (final a in actions)
          a: '${dir.path}${Platform.pathSeparator}$a.json',
      };
      await Future.wait([
        for (final e in files.entries) client.download(e.key, e.value, cancel),
      ]);
      return files;
    }

    Future<PlaylistData> parse(Map<String, String> files) => compute(
        parseXtreamFiles, (source.id, client.baseUrl, liveExt, files));

    final rest = download(const [
      'get_vod_categories',
      'get_series_categories',
      'get_vod_streams',
      'get_series',
    ])
      ..ignore(); // Awaited below; this only keeps an early error from being unhandled.
    try {
      final live = await parse(
          await download(const ['get_live_categories', 'get_live_streams']));
      await onLive?.call(live);
      final library = await parse(await rest);
      return PlaylistData(
        categories: [...live.categories, ...library.categories],
        channels: live.channels,
        vod: library.vod,
        series: library.series,
        fallbacks: live.fallbacks,
      );
    } catch (_) {
      cancel.cancel();
      rethrow;
    } finally {
      // Downloads still writing would keep the folder from being deleted.
      await rest.then((_) {}, onError: (_) {});
      await dir.delete(recursive: true);
    }
  }

  /// Many panels disable xmltv.php (a 404, or an HTML page), so the per-channel
  /// JSON API backs it up.
  @override
  Future<List<EpgProgram>> fetchEpg(
      Source source, Map<String, String> wanted) async {
    final client = await _client(source);
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
    final body = await (await _client(source)).shortEpg(rawId(channel.id));
    return parseShortEpg(body, channel.epgKey);
  }

  Future<List<Episode>> fetchEpisodes(Source source, SeriesItem series) async {
    final client = await _client(source);
    final body = await client.seriesInfo(rawId(series.id));
    return parseEpisodes(body, series, client.baseUrl);
  }
}

/// Strips the `<sourceId>:` prefix from a stored id.
String rawId(String id) => id.substring(id.indexOf(':') + 1);

/// Stands in for the login inside stored Xtream stream URLs, so the database
/// never holds it. [withLogin] fills it in at play time.
const loginPlaceholder = '{user}/{pass}';

/// [url] with the login in place of [loginPlaceholder]. Other URLs pass as is.
String withLogin(String url, String username, String password) =>
    url.replaceFirst('/$loginPlaceholder/',
        '/${Uri.encodeComponent(username)}/${Uri.encodeComponent(password)}/');

class XtreamCatalogJob {
  const XtreamCatalogJob({
    required this.sourceId,
    required this.baseUrl,
    this.liveExt = 'ts',
    this.liveCategories = '[]',
    this.vodCategories = '[]',
    this.seriesCategories = '[]',
    this.live = '[]',
    this.vod = '[]',
    this.series = '[]',
  });

  final int sourceId;
  final String baseUrl;

  /// `ts`, or `m3u8` on panels that only allow HLS.
  final String liveExt;
  final String liveCategories, vodCategories, seriesCategories;
  final String live, vod, series;
}

/// Isolate entry point: reads the lists [XtreamBackend.fetch] saved, keyed by
/// action. A list not given counts as empty.
PlaylistData parseXtreamFiles((int, String, String, Map<String, String>) job) {
  final (sourceId, baseUrl, liveExt, files) = job;
  String read(String action) => switch (files[action]) {
        final path? =>
          utf8.decode(File(path).readAsBytesSync(), allowMalformed: true),
        null => '[]',
      };
  return parseXtreamCatalog(XtreamCatalogJob(
    sourceId: sourceId,
    baseUrl: baseUrl,
    liveExt: liveExt,
    liveCategories: read('get_live_categories'),
    vodCategories: read('get_vod_categories'),
    seriesCategories: read('get_series_categories'),
    live: read('get_live_streams'),
    vod: read('get_vod_streams'),
    series: read('get_series'),
  ));
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
        streamUrl: '${job.baseUrl}/live/$loginPlaceholder/$id.${job.liveExt}',
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
        streamUrl: '${job.baseUrl}/movie/$loginPlaceholder/$id.$ext',
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

List<Episode> parseEpisodes(String body, SeriesItem series, String baseUrl) {
  final json = jsonDecode(body);
  final episodes = json is Map ? json['episodes'] : null;
  // A map keyed by season number, or a list of seasons on some panels.
  final seasons = switch (episodes) {
    Map m => m.values,
    List l => l,
    _ => const [],
  };
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
          streamUrl: '$baseUrl/series/$loginPlaceholder/$id.$ext',
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
