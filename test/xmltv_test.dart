import 'dart:convert';
import 'dart:io';

import 'package:cloud_iptv/services/xmltv_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const guide = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="a"><display-name>Not a programme title</display-name></channel>
  <programme start="20300101120000 +0100" stop="20300101130000 +0100" channel="a">
    <title lang="en">News &amp; Weather</title>
    <title lang="no">Nyheter</title>
    <desc><![CDATA[Daily <news>]]></desc>
  </programme>
  <programme start="20300101120000 +0000" stop="20300101130000 +0000" channel="other">
    <title>Unwanted</title>
  </programme>
  <programme start="20000101120000 +0000" stop="20000101130000 +0000" channel="a">
    <title>Expired</title>
  </programme>
  <programme start="garbage" stop="20300101130000 +0000" channel="a">
    <title>Bad date</title>
  </programme>
</tv>''';

void main() {
  final notBefore = DateTime.utc(2029);

  test('keeps only wanted, current, well-formed programmes', () async {
    // Split mid-element: stream chunks do not respect tag boundaries.
    final chunks = [guide.substring(0, 200), guide.substring(200)];
    final programs =
        await parseXmltv(Stream.fromIterable(chunks), {'a'}, notBefore);
    final p = programs.single;
    expect(p.title, 'News & Weather');
    expect(p.description, 'Daily <news>');
    expect(p.startTime, DateTime.utc(2030, 1, 1, 11));
  });

  test('parses dates with and without offsets', () {
    expect(parseXmltvDate('20240101120000 -0530'),
        DateTime.utc(2024, 1, 1, 17, 30));
    expect(parseXmltvDate('20240101120000'), DateTime.utc(2024, 1, 1, 12));
    expect(parseXmltvDate('nonsense'), isNull);
    expect(parseXmltvDate(null), isNull);
  });

  test('reads plain and gzipped files', () async {
    final dir = await Directory.systemTemp.createTemp('xmltv_test');
    addTearDown(() => dir.delete(recursive: true));
    final plain = File('${dir.path}/g.xml')..writeAsStringSync(guide);
    final zipped = File('${dir.path}/g.xml.gz')
      ..writeAsBytesSync(gzip.encode(utf8.encode(guide)));
    for (final f in [plain, zipped]) {
      final programs = await parseXmltvFile(XmltvJob(f.path, {'a'}, notBefore));
      expect(programs, hasLength(1));
    }
  });
}
