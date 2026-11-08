import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'playlist_backend.dart';
import 'tmdb.dart' show yearInTitle;

class M3uBackend implements PlaylistBackend {
  M3uBackend(this._dio);
  final Dio _dio;

  @override
  Future<PlaylistData?> fetch(Source source) async {
    final dir = await Directory.systemTemp.createTemp('cloud_iptv_m3u');
    try {
      final path = '${dir.path}${Platform.pathSeparator}playlist.m3u';
      final response = await _dio.download(
        source.url,
        path,
        options: Options(
          headers: {if (source.etag != null) 'If-None-Match': source.etag},
          validateStatus: (s) => s != null && (s < 300 || s == 304),
        ),
      );
      if (response.statusCode == 304) return null;
      final parsed = await compute(parseM3uFile, (path, source.id));
      return PlaylistData(
        categories: parsed.categories,
        channels: parsed.channels,
        vod: parsed.vod,
        fallbacks: parsed.fallbacks,
        epgUrl: parsed.epgUrl,
        etag: response.headers.value('etag'),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<List<EpgProgram>> fetchEpg(
          Source source, Map<String, String> wanted) async =>
      source.epgUrl == null
          ? []
          : fetchXmltv(_dio, source.epgUrl!, wanted.keys.toSet());
}

/// Isolate entry point. Reads the file as a stream, so a 50MB+ playlist never
/// exists as one string.
Future<PlaylistData> parseM3uFile((String, int) job) {
  final (path, sourceId) = job;
  final lines = File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  return parseM3uLines(lines, sourceId);
}

final _attribute = RegExp(r'([\w-]+)="([^"]*)"');
const _vodExtensions = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v'];

Future<PlaylistData> parseM3uLines(Stream<String> lines, int sourceId) async {
  final channels = <PlaylistChannel>[];
  final vod = <VodItem>[];
  final categories = <String, Category>{};
  final seen = <String, int>{};
  String? epgUrl;
  String? extinf;
  String? extgrp;

  await for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('#EXTM3U')) {
      final attrs = _attributes(line);
      final url = attrs['url-tvg'] ?? attrs['x-tvg-url'];
      if (url != null && url.isNotEmpty) epgUrl = url.split(',').first.trim();
    } else if (line.startsWith('#EXTINF')) {
      extinf = line;
      extgrp = null;
    } else if (line.startsWith('#EXTGRP:')) {
      extgrp = line.substring(8).trim();
    } else if (line.isNotEmpty && !line.startsWith('#') && extinf != null) {
      final header = extinf;
      extinf = null;
      if (!isSafeStreamUrl(line)) continue;

      final (attrPart, displayName) = _splitExtinf(header);
      final attrs = _attributes(attrPart);
      final name = displayName.isNotEmpty
          ? displayName
          : attrs['tvg-name'] ?? 'Unnamed';
      final tvgId = _nonEmpty(attrs['tvg-id']);
      final logo = _nonEmpty(attrs['tvg-logo']);
      final group =
          _nonEmpty(attrs['group-title']) ?? _nonEmpty(extgrp) ?? 'Uncategorized';
      final kind = _isVod(line) ? CategoryKind.vod : CategoryKind.live;

      final categoryId = '$sourceId:${kind.name}:$group';
      categories[categoryId] ??= Category(
          id: categoryId, sourceId: sourceId, name: group, kind: kind);

      // Stable across syncs, unlike tokenised URLs, so favourites survive.
      final key = '${tvgId ?? ''}|$name';
      final occurrence = seen[key] = (seen[key] ?? -1) + 1;
      final id = '$sourceId:$key${occurrence == 0 ? '' : '#$occurrence'}';

      if (kind == CategoryKind.vod) {
        vod.add(VodItem(
          id: id,
          sourceId: sourceId,
          title: name,
          posterUrl: logo,
          streamUrl: line,
          categoryId: categoryId,
          year: yearInTitle(name),
          sortOrder: vod.length,
        ));
      } else {
        channels.add(PlaylistChannel(
          id: id,
          sourceId: sourceId,
          name: name,
          logoUrl: logo,
          streamUrl: line,
          categoryId: categoryId,
          tvgId: tvgId,
          backendType: BackendType.m3u,
          sortOrder: channels.length,
        ));
      }
    }
  }

  return PlaylistData(
    categories: categories.values.toList(),
    channels: channels,
    vod: vod,
    fallbacks: fallbacksFor(channels),
    epgUrl: epgUrl,
  );
}

Map<String, String> _attributes(String text) => {
      for (final m in _attribute.allMatches(text)) m[1]!.toLowerCase(): m[2]!,
    };

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// Splits on the first comma outside quotes: attribute values may hold commas
/// and display names may hold quotes.
(String, String) _splitExtinf(String line) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x22) {
      quoted = !quoted;
    } else if (c == 0x2C && !quoted) {
      return (line.substring(0, i), line.substring(i + 1).trim());
    }
  }
  return (line, '');
}

bool _isVod(String url) {
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  return path.contains('/movie/') ||
      path.contains('/series/') ||
      _vodExtensions.any(path.endsWith);
}
