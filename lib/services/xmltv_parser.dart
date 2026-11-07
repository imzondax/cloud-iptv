import 'dart:convert';
import 'dart:io';

import 'package:xml/xml_events.dart';

import '../models/models.dart';

class XmltvJob {
  const XmltvJob(this.path, this.wanted, this.notBefore);
  final String path;
  final Set<String> wanted;
  final DateTime notBefore;
}

/// Isolate entry point. Accepts plain or gzipped XMLTV and streams it, keeping
/// only programmes for known channels: full guides are mostly irrelevant rows.
Future<List<EpgProgram>> parseXmltvFile(XmltvJob job) async {
  final file = File(job.path);
  final magic = await file.openRead(0, 2).expand((b) => b).toList();
  final isGzip = magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b;
  final bytes = isGzip
      ? file.openRead().transform(gzip.decoder)
      : file.openRead();
  final text = bytes.transform(const Utf8Decoder(allowMalformed: true));
  return parseXmltv(text, job.wanted, job.notBefore);
}

Future<List<EpgProgram>> parseXmltv(
    Stream<String> xml, Set<String> wanted, DateTime notBefore) async {
  final out = <EpgProgram>[];
  String? channel, title, description, field;
  DateTime? start, stop;

  await for (final event in xml.toXmlEvents().normalizeEvents().flatten()) {
    switch (event) {
      case XmlStartElementEvent(name: 'programme', :final attributes):
        String? attr(String n) =>
            attributes.where((a) => a.name == n).firstOrNull?.value;
        channel = attr('channel');
        start = parseXmltvDate(attr('start'));
        stop = parseXmltvDate(attr('stop'));
        title = description = null;
      case XmlStartElementEvent(:final name, isSelfClosing: false)
          when channel != null && (name == 'title' || name == 'desc'):
        field = name;
      case XmlTextEvent(:final value) when field == 'title':
        title ??= value;
      case XmlTextEvent(:final value) when field == 'desc':
        description ??= value;
      case XmlCDATAEvent(:final value) when field == 'title':
        title ??= value;
      case XmlCDATAEvent(:final value) when field == 'desc':
        description ??= value;
      case XmlEndElementEvent(name: 'title' || 'desc'):
        field = null;
      case XmlEndElementEvent(name: 'programme'):
        if (channel != null &&
            wanted.contains(channel) &&
            title != null &&
            start != null &&
            stop != null &&
            stop.isAfter(notBefore)) {
          out.add(EpgProgram(
            channelId: channel,
            title: title,
            startTime: start,
            stopTime: stop,
            description: description,
          ));
        }
        channel = null;
      default:
        break;
    }
  }
  return out;
}

final _xmltvDate =
    RegExp(r'^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)\s*([+-])?(\d\d)?(\d\d)?');

/// `20240101120000 +0100` to UTC. A missing offset means UTC, per the XMLTV DTD.
DateTime? parseXmltvDate(String? value) {
  final m = value == null ? null : _xmltvDate.firstMatch(value.trim());
  if (m == null) return null;
  int n(int i) => int.parse(m[i]!);
  final utc = DateTime.utc(n(1), n(2), n(3), n(4), n(5), n(6));
  if (m[7] == null || m[8] == null) return utc;
  final offset = Duration(hours: n(8), minutes: m[9] == null ? 0 : n(9));
  return m[7] == '+' ? utc.subtract(offset) : utc.add(offset);
}
