import 'dart:convert';

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/xtream_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

XtreamCatalogJob job({
  String live = '[]',
  String vod = '[]',
  String series = '[]',
  String liveCategories = '[]',
}) =>
    XtreamCatalogJob(
      sourceId: 3,
      baseUrl: 'http://x.test:8080',
      liveCategories: liveCategories,
      vodCategories: '[]',
      seriesCategories: '[]',
      live: live,
      vod: vod,
      series: series,
    );

void main() {
  test('normalizes the base URL', () {
    expect(XtreamClient.normalizeBaseUrl(' http://x.test:80/ '), 'http://x.test:80');
    expect(
        XtreamClient.normalizeBaseUrl(
            'http://x.test/player_api.php?username=a&password=b'),
        'http://x.test');
  });

  test('maps live streams into the shared entity, without the login', () {
    final data = parseXtreamCatalog(job(
      liveCategories: '[{"category_id":"5","category_name":"News"}]',
      live: '[{"stream_id":42,"name":"CNN","stream_icon":"http://l/c.png",'
          '"category_id":"5","epg_channel_id":"cnn.us"}]',
    ));
    final c = data.channels.single;
    expect(c.id, '3:42');
    expect(c.streamUrl, 'http://x.test:8080/live/{user}/{pass}/42.ts');
    expect(withLogin(c.streamUrl, 'us er', 'p/w'),
        'http://x.test:8080/live/us%20er/p%2Fw/42.ts');
    expect(withLogin('http://m3u.test/a.ts', 'u', 'p'), 'http://m3u.test/a.ts');
    expect(c.tvgId, 'cnn.us');
    expect(c.backendType, BackendType.xtream);
    expect(c.categoryId, data.categories.single.id);
  });

  test('panels that only allow HLS get .m3u8 live links', () {
    final data = parseXtreamCatalog(XtreamCatalogJob(
      sourceId: 3,
      baseUrl: 'http://x.test',
      liveExt: 'm3u8',
      live: '[{"stream_id":42,"name":"CNN"}]',
    ));
    expect(data.channels.single.streamUrl, endsWith('/42.m3u8'));
  });

  test('tolerates the types real panels send', () {
    final data = parseXtreamCatalog(job(
      live: '[{"stream_id":"1","name":null,"epg_channel_id":"","stream_icon":""},'
          '{"name":"no id"}]',
      vod: '[{"stream_id":2,"name":"Film","rating":"","year":"",'
          '"releaseDate":"2021-03-04","container_extension":"mkv"}]',
      series: '{}',
    ));
    expect(data.channels.single.name, 'Unnamed');
    expect(data.channels.single.tvgId, isNull);
    expect(data.channels.single.logoUrl, isNull);
    expect(data.vod.single.rating, isNull);
    expect(data.vod.single.year, 2021);
    expect(data.vod.single.streamUrl, endsWith('/2.mkv'));
    expect(data.series, isEmpty);
  });

  test('items in unlisted categories stay reachable', () {
    final data = parseXtreamCatalog(job(
      live: '[{"stream_id":1,"name":"Orphan","category_id":"99"},'
          '{"stream_id":2,"name":"None","category_id":null}]',
    ));
    expect(data.categories.map((c) => c.id).toSet(),
        data.channels.map((c) => c.categoryId).toSet());
  });

  test('files an item under every category, once each', () {
    final data = parseXtreamCatalog(job(
      vod: '[{"stream_id":1,"name":"Film","category_id":"4","category_ids":[4,8]},'
          '{"stream_id":1,"name":"Film","category_id":"8","category_ids":[4,8]},'
          '{"stream_id":1,"name":"Film","category_id":"12"}]',
      series: '[{"series_id":2,"name":"Show","category_id":"4",'
          '"category_ids":[4,8,12]}]',
    ));
    expect(data.vod.map((v) => v.categoryId),
        ['3:vod:4', '3:vod:8', '3:vod:12']);
    expect(data.vod.map((v) => v.id).toSet(), {'3:1'});
    expect(data.series, hasLength(3));
  });

  test('reads a missing movie year from the title', () {
    final data = parseXtreamCatalog(job(
      vod: '[{"stream_id":1,"name":"Bury Him (2024)","year":""},'
          '{"stream_id":2,"name":"2012 (2009)"},'
          '{"stream_id":3,"name":"Heat","year":"1995"}]',
    ));
    expect(data.vod.map((v) => v.year), [2024, 2009, 1995]);
  });

  test('keeps the director and genre of a series', () {
    final data = parseXtreamCatalog(job(
      series: '[{"series_id":2,"name":"Show","category_id":"4",'
          '"director":"Jane Doe","genre":" Drama / Crime "},'
          '{"series_id":3,"name":"Other","category_id":"4","director":""}]',
    ));
    expect(data.series.first.director, 'Jane Doe');
    expect(data.series.first.genre, 'Drama / Crime');
    expect(data.series.last.director, isNull);
  });

  test('decodes base64 short EPG', () {
    String b(String s) => base64.encode(utf8.encode(s));
    final programs = parseShortEpg(
      jsonEncode({
        'epg_listings': [
          {
            'title': b('Nyheter på NRK'),
            'description': b('Kveld'),
            'start_timestamp': '1700000000',
            'stop_timestamp': 1700003600,
          },
          {'title': b('broken')},
        ]
      }),
      'nrk1.no',
    );
    final p = programs.single;
    expect(p.title, 'Nyheter på NRK');
    expect(p.channelId, 'nrk1.no');
    expect(p.stopTime.difference(p.startTime), const Duration(hours: 1));
  });

  test('reads episodes as a season map or a season list', () {
    const series = SeriesItem(
        id: '3:9', sourceId: 3, title: 'Show', categoryId: 'c', sortOrder: 0);
    const episode = '{"id":"77","episode_num":2,"season":1,"title":"Two",'
        '"container_extension":"mp4"}';
    for (final body in [
      '{"episodes":{"1":[$episode]}}',
      '{"episodes":[[$episode]]}',
    ]) {
      final e = parseEpisodes(body, series, 'http://x.test').single;
      expect(e.item.title, endsWith(' · S1E2  Two'));
      expect(e.item.streamUrl, 'http://x.test/series/{user}/{pass}/77.mp4');
      expect((e.season, e.number, e.name), (1, 2, 'Two'));
    }
    expect(parseEpisodes('{"episodes":[]}', series, 'b'), isEmpty);
  });

  test('error messages never contain the credentials in the URL', () {
    final request = RequestOptions(
        path: 'http://x.test/player_api.php?username=me&password=secret');
    for (final e in [
      DioException(requestOptions: request, message: request.path),
      DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 403)),
      DioException.connectionTimeout(
          timeout: Duration.zero, requestOptions: request),
    ]) {
      expect(safeError(e), isNot(contains('secret')));
    }
  });
}
