import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'xmltv_parser.dart';

/// Everything one source contributes, already normalized.
class PlaylistData {
  const PlaylistData({
    this.categories = const [],
    this.channels = const [],
    this.vod = const [],
    this.series = const [],
    this.fallbacks = const [],
    this.etag,
    this.epgUrl,
  });

  final List<Category> categories;
  final List<PlaylistChannel> channels;
  final List<VodItem> vod;
  final List<SeriesItem> series;
  final List<StreamFallback> fallbacks;
  final String? etag;
  final String? epgUrl;

  bool get isEmpty => channels.isEmpty && vod.isEmpty && series.isEmpty;
}

/// The one seam between remote formats and the rest of the app.
abstract interface class PlaylistBackend {
  /// Returns null when the remote playlist is unchanged since the last sync.
  /// A backend that has the live channels first may hand them to [onLive].
  Future<PlaylistData?> fetch(Source source,
      {Future<void> Function(PlaylistData live)? onLive});

  /// Programmes for the tvg-ids in [wanted], which maps each one to a channel
  /// id carrying it. Empty when the source has no guide.
  Future<List<EpgProgram>> fetchEpg(Source source, Map<String, String> wanted);
}

const _streamSchemes = {
  'http', 'https', 'rtmp', 'rtmps', 'rtsp', 'rtp', 'udp', 'mms', 'mmsh',
};

/// Playlists are untrusted, and mpv also opens `file://`, `edl://`, `lavfi://`
/// and friends, so only network schemes may ever reach the player.
bool isSafeStreamUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      _streamSchemes.contains(uri.scheme.toLowerCase()) &&
      uri.host.isNotEmpty;
}

/// Channels sharing a tvg-id carry the same programme, so each one backs the
/// others up. Providers rarely publish explicit mirrors.
List<StreamFallback> fallbacksFor(List<PlaylistChannel> channels,
    {int maxPerChannel = 3}) {
  final byTvgId = <String, List<PlaylistChannel>>{};
  for (final c in channels) {
    if (c.tvgId != null) (byTvgId[c.tvgId!] ??= []).add(c);
  }
  final out = <StreamFallback>[];
  for (final group in byTvgId.values) {
    if (group.length < 2) continue;
    for (final c in group) {
      final urls = group
          .map((o) => o.streamUrl)
          .where((u) => u != c.streamUrl)
          .toSet()
          .take(maxPerChannel);
      var priority = 0;
      for (final url in urls) {
        out.add(StreamFallback(
            channelId: c.id, url: url, priority: priority++));
      }
    }
  }
  return out;
}

/// Downloads an XMLTV guide to a temp file and parses it off the main isolate.
Future<List<EpgProgram>> fetchXmltv(
    Dio dio, String url, Set<String> wanted) async {
  final dir = await Directory.systemTemp.createTemp('cloud_iptv_epg');
  try {
    final path = '${dir.path}${Platform.pathSeparator}guide.xml';
    await dio.download(url, path);
    return await compute(
      parseXmltvFile,
      XmltvJob(path, wanted,
          DateTime.now().toUtc().subtract(const Duration(days: 1))),
    );
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Dio's messages embed the request URL, which holds Xtream credentials, so
/// nothing from them may reach the UI or logs.
String safeError(Object e) => switch (e) {
      DioException(response: final r?) => 'Server returned HTTP ${r.statusCode}',
      DioException(type: DioExceptionType.connectionTimeout) ||
      DioException(type: DioExceptionType.receiveTimeout) =>
        'The server timed out',
      DioException() => 'Could not reach the server',
      FormatException() => 'The server sent an invalid response',
      PlaylistException(:final message) => message,
      _ => 'Something went wrong',
    };

class PlaylistException implements Exception {
  const PlaylistException(this.message);
  final String message;
}
