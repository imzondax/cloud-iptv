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

/// A poster for one title, for catalogs that came without artwork.
Future<String?> searchTmdbPoster(Dio dio, String key,
    {required String title, int? year, required bool tv}) async {
  final token = key.contains('.');
  final response = await dio.get<Map<String, dynamic>>(
    'https://api.themoviedb.org/3/search/${tv ? 'tv' : 'movie'}',
    queryParameters: {
      'query': title,
      if (year != null) (tv ? 'first_air_date_year' : 'year'): '$year',
      if (!token) 'api_key': key,
    },
    options: Options(headers: {if (token) 'Authorization': 'Bearer $key'}),
  );
  final results = response.data?['results'];
  if (results is! List) return null;
  for (final r in results.whereType<Map<String, dynamic>>()) {
    final path = r['poster_path'];
    if (path is String) return 'https://image.tmdb.org/t/p/w342$path';
  }
  return null;
}

/// One key per movie or series, however the provider spells or tags it.
String titleKey({required bool tv, required String title, int? year}) =>
    '${tv ? 'tv' : 'movie'}:${normalizeTitle(title)}:${year ?? ''}';

/// Language, studios and age limit for one title, or a bare row when TMDB
/// has no match. Network errors throw, so those titles are tried again.
Future<TitleDetail> fetchTmdbDetails(Dio dio, String apiKey,
    {required String key,
    required String title,
    int? year,
    required bool tv}) async {
  final token = apiKey.contains('.');
  Future<Map<String, dynamic>> get(String path, Map<String, String> q) async =>
      (await dio.get<Map<String, dynamic>>(
        'https://api.themoviedb.org/3/$path',
        queryParameters: {...q, if (!token) 'api_key': apiKey},
        options:
            Options(headers: {if (token) 'Authorization': 'Bearer $apiKey'}),
      ))
          .data ??
      const {};
  final kind = tv ? 'tv' : 'movie';
  final found = await get('search/$kind', {
    'query': searchableTitle(title),
    if (year != null) (tv ? 'first_air_date_year' : 'year'): '$year',
  });
  final results = found['results'];
  final first = results is List
      ? results.whereType<Map<String, dynamic>>().firstOrNull
      : null;
  if (first == null) return TitleDetail(key: key);
  final details = await get('$kind/${first['id']}', {
    'append_to_response': tv ? 'content_ratings' : 'release_dates',
  });
  return parseTmdbDetails(key, details);
}

/// Reads a TMDB movie or TV details body, with its ratings appended.
TitleDetail parseTmdbDetails(String key, Map<String, dynamic> body) {
  final ratings = <String, String>{};
  // TV: content_ratings.results[].rating. Movies: one per release.
  for (final r in _maps((body['content_ratings'] as Map?)?['results'])) {
    if (r['rating'] case final String rating when rating.isNotEmpty) {
      ratings.putIfAbsent('${r['iso_3166_1']}', () => rating);
    }
  }
  for (final country in _maps((body['release_dates'] as Map?)?['results'])) {
    for (final r in _maps(country['release_dates'])) {
      if (r['certification'] case final String c when c.isNotEmpty) {
        ratings.putIfAbsent('${country['iso_3166_1']}', () => c);
      }
    }
  }
  final studios = [
    for (final c in _maps(body['production_companies']))
      if (c['name'] case final String name when name.isNotEmpty) name,
  ].take(3).join(', ');
  return TitleDetail(
    key: key,
    language: switch (body['original_language']) {
      final String l when l.isNotEmpty => l,
      _ => null,
    },
    studios: studios.isEmpty ? null : studios,
    ageLimit: ageFromRating(ratings['NO']) ?? ageFromRating(ratings['US']),
  );
}

Iterable<Map> _maps(Object? list) =>
    list is List ? list.whereType<Map>() : const [];

/// shortcut: US letters map to the age they roughly mean; extend the table
/// for other countries if Norway and the US both lack a rating.
const _usAges = {
  'G': 0, 'TV-Y': 0, 'TV-G': 0, 'TV-Y7': 7, 'PG': 10, 'TV-PG': 10,
  'PG-13': 13, 'TV-14': 14, 'R': 17, 'TV-MA': 17, 'NC-17': 18,
};

/// Norway's `A`, `6` … `18`, or a US rating, as the lowest allowed age.
int? ageFromRating(String? rating) {
  if (rating == null) return null;
  if (rating == 'A') return 0;
  return _usAges[rating] ??
      int.tryParse(RegExp(r'\d+').firstMatch(rating)?[0] ?? '');
}

/// The title a search should use: the provider's, without its tags.
String searchableTitle(String raw) {
  var t = raw.trim();
  // Tags first and repeatedly: providers stack them, as in `4K | EN - Title`.
  while (_tagPrefix.hasMatch(t)) {
    t = t.replaceFirst(_tagPrefix, '');
  }
  t = t
      .replaceAll(_bracketed, ' ')
      .replaceFirst(_releaseTags, '')
      .replaceFirst(_qualitySuffix, '')
      .trim();
  return t.replaceFirst(_trailingYear, '');
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
final _qualitySuffix = RegExp(r'\s+(4k|uhd|fhd|hd|sd|hevc|multi[- ]?(sub|audio))\s*$',
    caseSensitive: false);
final _trailingYear = RegExp(r'\s+(19|20)\d\d$');
// Capitals only, so a title such as `The French` keeps its last word.
final _releaseTags = RegExp(r'(\s+(NORDIC|REPACK|HYBRID|SUBBED|DUBBED|INTERNAL|'
    r'FRENCH|SUBFRENCH|FLEMISH|DANISH|NORWEGIAN|SWEDISH|FINNISH|DL))+\s*$');
final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _yearInTitle = RegExp(r'[\[(]((?:19|20)\d\d)[\])]|\s((?:19|20)\d\d)\s*$');

/// Reduces provider and TMDB spellings to one comparable form, so that
/// `EN - The Matrix (1999) [4K]` and `The Matrix` meet.
String normalizeTitle(String raw) {
  var t = searchableTitle(raw).toLowerCase().replaceAll('&', ' and ');
  t = t.replaceAll(_punctuation, ' ').trim().replaceFirst(_trailingYear, '');
  return t.startsWith('the ') ? t.substring(4) : t;
}

/// A year written into a title, as in `Heat (1995)` or `Heat 1995`.
int? yearInTitle(String title) {
  final match = _yearInTitle.firstMatch(title);
  return match == null ? null : int.parse(match[1] ?? match[2]!);
}

int? _yearOf(CatalogTitle item) => item.year ?? yearInTitle(item.title);

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
