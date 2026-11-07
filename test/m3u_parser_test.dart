import 'dart:io';

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/services/m3u_parser.dart';
import 'package:cloud_iptv/services/playlist_backend.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PlaylistData> parse(String text) =>
    parseM3uLines(Stream.fromIterable(text.split('\n')), 7);

void main() {
  test('extracts standard tags and the guide URL', () async {
    final data = await parse('''
#EXTM3U url-tvg="http://epg.test/a.xml,http://epg.test/b.xml"
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://l.test/b.png" group-title="UK",BBC One
http://s.test/1.ts
''');
    final c = data.channels.single;
    expect(c.name, 'BBC One');
    expect(c.tvgId, 'bbc1.uk');
    expect(c.logoUrl, 'http://l.test/b.png');
    expect(c.streamUrl, 'http://s.test/1.ts');
    expect(c.backendType, BackendType.m3u);
    expect(data.categories.single.name, 'UK');
    expect(c.categoryId, data.categories.single.id);
    expect(data.epgUrl, 'http://epg.test/a.xml');
  });

  test('handles commas in attributes and quotes in names', () async {
    final data = await parse('''
#EXTINF:-1 group-title="News, Sport",The "Best" TV, HD
http://s.test/1.ts
''');
    expect(data.channels.single.name, 'The "Best" TV, HD');
    expect(data.categories.single.name, 'News, Sport');
  });

  test('never passes non-network URLs to the player', () async {
    final data = await parse('''
#EXTINF:-1,Evil file
file:///C:/Windows/win.ini
#EXTINF:-1,Evil edl
edl://http://x.test/a;
#EXTINF:-1,Evil lavfi
lavfi://color
#EXTINF:-1,Good
https://s.test/1.m3u8
''');
    expect(data.channels.map((c) => c.name), ['Good']);
  });

  test('a skipped entry does not lend its header to the next URL', () async {
    final data = await parse('''
#EXTINF:-1,Evil
file:///etc/passwd
http://orphan.test/1.ts
''');
    expect(data.channels, isEmpty);
  });

  test('separates VOD from live and uses EXTGRP as a fallback', () async {
    final data = await parse('''
#EXTINF:-1,Movie
http://s.test/movie/u/p/1.mkv
#EXTINF:-1,Live
#EXTGRP:Fallback Group
http://s.test/live/u/p/2.ts
''');
    expect(data.vod.single.title, 'Movie');
    expect(data.channels.single.name, 'Live');
    expect(
        data.categories.map((c) => (c.name, c.kind)),
        containsAll([
          ('Uncategorized', CategoryKind.vod),
          ('Fallback Group', CategoryKind.live),
        ]));
  });

  test('ids are unique and survive a URL change', () async {
    const playlist = '''
#EXTINF:-1 tvg-id="a",Same
http://s.test/TOKEN/1.ts
#EXTINF:-1 tvg-id="a",Same
http://s.test/TOKEN/2.ts
''';
    final first = await parse(playlist);
    final second = await parse(playlist.replaceAll('TOKEN', 'rotated'));
    expect(first.channels.map((c) => c.id).toSet(), hasLength(2));
    expect(second.channels.map((c) => c.id), first.channels.map((c) => c.id));
  });

  test('channels sharing a tvg-id back each other up', () async {
    final data = await parse('''
#EXTINF:-1 tvg-id="a",One HD
http://s.test/hd.ts
#EXTINF:-1 tvg-id="a",One SD
http://s.test/sd.ts
#EXTINF:-1,No id
http://s.test/none.ts
''');
    final hd = data.channels.first;
    expect(data.fallbacks.where((f) => f.channelId == hd.id).single.url,
        'http://s.test/sd.ts');
    expect(data.fallbacks, hasLength(2));
  });

  test('parses a 50MB+ file from disk, tolerating bad UTF-8', () async {
    final dir = await Directory.systemTemp.createTemp('m3u_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/big.m3u');
    final sink = file.openWrite()..writeln('\uFEFF#EXTM3U');
    const count = 350000;
    for (var i = 0; i < count; i++) {
      sink
        ..writeln('#EXTINF:-1 tvg-id="ch$i.test" tvg-logo="http://logo.test/'
            '$i.png" group-title="Group ${i % 40}",Channel $i')
        ..writeln('http://stream.test/live/user/pass/$i.ts');
    }
    sink.add([0x23, 0x45, 0x58, 0x54, 0x49, 0x4E, 0x46, 0x3A, 0x2D, 0x31, 0x2C,
        0xE6, 0x0A, 0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F, 0x78, 0x2F, 0x31,
        0x0A]);
    await sink.close();
    expect(await file.length(), greaterThan(50 * 1024 * 1024));

    final data = await parseM3uFile((file.path, 1));
    expect(data.channels, hasLength(count + 1));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
