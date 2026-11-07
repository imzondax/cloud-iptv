import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'playlist_backend.dart';

/// The languages counted as western film and television.
const _western = {
  'en', 'fr', 'de', 'es', 'it', 'nl', 'pt', 'sv', 'da', 'no', 'nb', 'fi', 'is',
};

const _pages = 3;

const tmdbShelves = [
  (name: 'Trending movies', kind: CategoryKind.vod,
      path: 'trending/movie/week', query: <String, String>{}),
  (name: 'Top rated movies', kind: CategoryKind.vod,
      path: 'movie/top_rated', query: <String, String>{}),
  (name: 'Westerns', kind: CategoryKind.vod, path: 'discover/movie', query: {
    'with_genres': '37',
    'sort_by': 'vote_average.desc',
    'vote_count.gte': '300',
  }),
  (name: 'Trending series', kind: CategoryKind.series,
      path: 'trending/tv/week', query: <String, String>{}),
  (name: 'Top rated series', kind: CategoryKind.series,
      path: 'tv/top_rated', query: <String, String>{}),
];

typedef TmdbTitle = ({String title, String original, int? year});
typedef TmdbList = ({String name, CategoryKind kind, List<TmdbTitle> titles});
typedef CatalogTitle = ({String id, String title, int? year});

/// Western titles from one page of a movie or TV list.
List<TmdbTitle> parseTmdbPage(Map<String, dynamic> body) {
  final results = body['results'];
  if (results is! List) throw const FormatException('No results');
  return [
    for (final r in results.whereType<Map<String, dynamic>>())
      if (_western.contains(r['original_language']))
        (
          title: (r['title'] ?? r['name'] ?? '') as String,
          original: (r['original_title'] ?? r['original_name'] ?? '') as String,
          year: int.tryParse(
              ((r['release_date'] ?? r['first_air_date'] ?? '') as String)
                  .split('-')
                  .first),
        ),
  ];
}

class TmdbClient {
  TmdbClient(this._dio);

  final Dio _dio;

  /// [key] is a v3 API key, or a v4 read token, which is a dotted JWT.
  Future<List<TmdbList>> fetch(String key) async {
    final token = key.contains('.');
    Future<List<TmdbTitle>> page(String path, Map<String, String> query, int n) async {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.themoviedb.org/3/$path',
        queryParameters: {...query, 'page': '$n', if (!token) 'api_key': key},
        options: Options(
            headers: {if (token) 'Authorization': 'Bearer $key'}),
      );
      return parseTmdbPage(response.data ?? const {});
    }

    try {
      return await Future.wait([
        for (final s in tmdbShelves)
          Future.wait([
            for (var n = 1; n <= _pages; n++) page(s.path, s.query, n),
          ]).then((pages) => (
                name: s.name,
                kind: s.kind,
                titles: pages.expand((p) => p).toList(),
              )),
      ]);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const PlaylistException('TMDB rejected this key');
      }
      rethrow;
    }
  }
}

String encodeTmdbLists(List<TmdbList> lists) => jsonEncode([
      for (final l in lists)
        {
          'name': l.name,
          'kind': l.kind.name,
          'titles': [
            for (final t in l.titles)
              {'title': t.title, 'original': t.original, 'year': t.year},
          ],
        },
    ]);

List<TmdbList> decodeTmdbLists(String json) => [
      for (final l in (jsonDecode(json) as List).cast<Map<String, dynamic>>())
        (
          name: l['name'] as String,
          kind: CategoryKind.values.byName(l['kind'] as String),
          titles: [
            for (final t
                in (l['titles'] as List).cast<Map<String, dynamic>>())
              (
                title: t['title'] as String,
                original: t['original'] as String,
                year: t['year'] as int?,
              ),
          ],
        ),
    ];

final _tagPrefix = RegExp(r'^(\|[A-Z0-9+]{2,5}\|\s*|[A-Z0-9+]{2,5}\s*[-|:]\s+)');
final _bracketed = RegExp(r'[\[(][^\])]*[\])]');
final _qualitySuffix =
    RegExp(r'\s+(4k|uhd|fhd|hd|sd|hevc|multi[- ]?(sub|audio))\s*$');
final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _yearInTitle = RegExp(r'[\[(]((?:19|20)\d\d)[\])]|\s((?:19|20)\d\d)\s*$');

/// Reduces provider and TMDB spellings to one comparable form, so that
/// `EN - The Matrix (1999) [4K]` and `The Matrix` meet.
String normalizeTitle(String raw) {
  var t = raw.trim();
  // Tags first and repeatedly: providers stack them, as in `4K | EN - Title`.
  while (_tagPrefix.hasMatch(t)) {
    t = t.replaceFirst(_tagPrefix, '');
  }
  t = t.replaceAll(_bracketed, ' ').toLowerCase();
  t = t.replaceFirst(_qualitySuffix, '').replaceAll('&', ' and ');
  t = t.replaceAll(_punctuation, ' ').trim();
  t = t.replaceFirst(RegExp(r'\s+(19|20)\d\d$'), '');
  return t.startsWith('the ') ? t.substring(4) : t;
}

int? _yearOf(CatalogTitle item) {
  if (item.year != null) return item.year;
  final match = _yearInTitle.firstMatch(item.title);
  return match == null ? null : int.parse(match[1] ?? match[2]!);
}

/// The catalog ids of [wanted], in its order, leaving out what is not there.
/// A known year must agree, or remakes would stand in for the original. Runs
/// in an isolate, as provider catalogs reach tens of thousands of titles.
List<String> matchCatalog(
    ({List<CatalogTitle> catalog, List<TmdbTitle> wanted}) job) {
  final index = <String, List<CatalogTitle>>{};
  for (final item in job.catalog) {
    (index[normalizeTitle(item.title)] ??= []).add(item);
  }
  final ids = <String>{};
  for (final want in job.wanted) {
    final candidates = [
      ...?index[normalizeTitle(want.title)],
      ...?index[normalizeTitle(want.original)],
    ];
    for (final item in candidates) {
      final year = _yearOf(item);
      if (year == null || want.year == null || (year - want.year!).abs() <= 1) {
        ids.add(item.id);
        break;
      }
    }
  }
  return ids.toList();
}
