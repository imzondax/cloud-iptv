import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:cloud_iptv/services/xtream_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers by URL, so a test can break one endpoint at a time.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options.uri);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody respond(String body, [int status = 200]) =>
    ResponseBody.fromString(body, status);

const xmltv = '<tv><programme start="20300101120000 +0000" '
    'stop="20300101130000 +0000" channel="a"><title>From XML</title>'
    '</programme></tv>';

String listing(String title) => jsonEncode({
      'epg_listings': [
        {
          'title': base64.encode(utf8.encode(title)),
          'start_timestamp': '1900000000',
          'stop_timestamp': '1900003600',
        }
      ]
    });

const source = Source(
    id: 1,
    type: BackendType.xtream,
    name: 'n',
    url: 'http://x.test',
    username: 'u',
    password: 'p');

const wanted = {'a': '1:10', 'b': '1:20'};

bool isXmltv(RequestOptions o) => o.uri.path.endsWith('xmltv.php');

void main() {
  (XtreamBackend, FakeAdapter) backend(
      ResponseBody Function(RequestOptions) handler) {
    final adapter = FakeAdapter((o) async => handler(o));
    return (XtreamBackend(Dio()..httpClientAdapter = adapter), adapter);
  }

  test('uses XMLTV when it works, with no per-channel calls', () async {
    final (b, adapter) = backend((_) => respond(xmltv));
    final programs = await b.fetchEpg(source, wanted);
    expect(programs.single.title, 'From XML');
    expect(adapter.requests, hasLength(1));
  });

  for (final (name, broken) in [
    ('a 404', () => respond('Not found', 404)),
    ('an HTML page', () => respond('<html><body>Hi</body></html>')),
    ('malformed XML', () => respond('<tv><programme')),
    ('an empty guide', () => respond('<tv></tv>')),
  ]) {
    test('falls back to the JSON API on $name', () async {
      final (b, _) = backend((o) => isXmltv(o)
          ? broken()
          : respond(listing('id ${o.uri.queryParameters['stream_id']}')));
      final programs = await b.fetchEpg(source, wanted);
      expect({for (final p in programs) p.channelId: p.title},
          {'a': 'id 10', 'b': 'id 20'});
    });
  }

  test('one failing channel does not lose the others', () async {
    final (b, _) = backend((o) {
      if (isXmltv(o)) return respond('', 404);
      return o.uri.queryParameters['stream_id'] == '10'
          ? respond('', 500)
          : respond(listing('kept'));
    });
    expect((await b.fetchEpg(source, wanted)).single.title, 'kept');
  });

  test('reports an error only when every channel fails', () async {
    final (b, _) = backend((_) => respond('', 404));
    await expectLater(b.fetchEpg(source, wanted), throwsA(isA<DioException>()));
  });

  ResponseBody panel(RequestOptions o, {String formats = '["m3u8"]'}) =>
      respond(switch (o.queryParameters['action']) {
        null => '{"user_info":{"auth":1,"allowed_output_formats":$formats}}',
        'get_live_streams' => '[{"stream_id":42,"name":"CNN"}]',
        'get_vod_streams' => '[{"stream_id":7,"name":"Heat"}]',
        _ => '[]',
      });

  test('a catalog sync keeps to the allowed formats and hands live on first',
      () async {
    final (b, _) = backend(panel);
    PlaylistData? early;
    final data = await b.fetch(source, onLive: (live) async => early = live);
    expect(early!.channels.single.streamUrl,
        'http://x.test/live/{user}/{pass}/42.m3u8');
    expect(early!.vod, isEmpty);
    expect(data!.channels, hasLength(1));
    expect(data.vod.single.title, 'Heat');
    expect(data.vod.single.streamUrl, 'http://x.test/movie/{user}/{pass}/7.mp4');

    final (ts, _) = backend((o) => panel(o, formats: '["m3u8","ts"]'));
    expect((await ts.fetch(source))!.channels.single.streamUrl, endsWith('.ts'));
  });

  test('a failed list fails the whole catalog sync', () async {
    final (b, _) = backend((o) => o.queryParameters['action'] == 'get_series'
        ? respond('', 500)
        : panel(o));
    await expectLater(b.fetch(source), throwsA(isA<DioException>()));
  });

  test('stops at the channel limit, 5 requests at a time at most', () async {
    var active = 0, peak = 0, calls = 0;
    final many = {for (var i = 0; i < 1200; i++) 'c$i': '1:$i'};
    final adapter = FakeAdapter((o) async {
      if (isXmltv(o)) return respond('', 404);
      calls++;
      if (++active > peak) peak = active;
      await Future<void>.delayed(Duration.zero);
      active--;
      return respond('{}');
    });
    await XtreamBackend(Dio()..httpClientAdapter = adapter)
        .fetchEpg(source, many);
    expect(calls, 1000);
    expect(peak, 5);
  });
}
