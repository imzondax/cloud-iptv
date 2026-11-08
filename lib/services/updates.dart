import 'package:dio/dio.dart';

/// Keep in step with `version` in pubspec.yaml; a test checks that it is.
const appVersion = '1.0.2';

const releasesUrl = 'https://github.com/imzondax/cloud-iptv/releases/latest';
const _latestRelease =
    'https://api.github.com/repos/imzondax/cloud-iptv/releases/latest';

/// Whether dotted version [latest] is above [current]. A leading `v` is fine.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp('^v'), '')
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// The newer version on GitHub, or null. Failing to check is never an error
/// worth showing: the repo may have no releases, or the user no connection.
Future<String?> findUpdate(Dio dio) async {
  try {
    final response = await dio.get<Map<String, dynamic>>(_latestRelease);
    final tag = response.data?['tag_name'];
    return tag is String && isNewerVersion(tag, appVersion) ? tag : null;
  } catch (_) {
    return null;
  }
}
