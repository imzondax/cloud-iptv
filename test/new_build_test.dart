import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _pubspec = '''
name: x
version: 1.2.3+4

description: y
msix_config:
  msix_version: 1.2.3.4
  display_name: z
''';

void main() {
  late Directory dir;
  final script = File('scripts/new_build.py').absolute.path;

  File file(String name) => File('${dir.path}/$name');

  Future<ProcessResult> run(List<String> notes) => Process.run(
        Platform.isWindows ? 'python' : 'python3',
        [script, ...notes],
        workingDirectory: dir.path,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('new_build');
    file('pubspec.yaml').writeAsStringSync(_pubspec);
    file('CHANGELOG.md').writeAsStringSync('# Changelog\n\n## Build 4\n');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('changes only the two version lines and adds the note', () async {
    final result = await run(['Fixed the guide']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      file('pubspec.yaml').readAsStringSync(),
      _pubspec
          .replaceFirst('version: 1.2.3+4', 'version: 1.2.3+5')
          .replaceFirst('msix_version: 1.2.3.4', 'msix_version: 1.2.3.5'),
    );
    final log = file('CHANGELOG.md').readAsStringSync();
    expect(log, startsWith('# Changelog\n\n## Build 5 (1.2.3) - '));
    expect(log, contains('- Fixed the guide\n'));
    expect(log, endsWith('## Build 4\n'));
  });

  test('a build without a note changes nothing', () async {
    final result = await run(['  ']);
    expect(result.exitCode, isNot(0));
    expect(file('pubspec.yaml').readAsStringSync(), _pubspec);
  });

  test('a pubspec without an MSIX version changes nothing', () async {
    final pubspec = _pubspec.replaceFirst('  msix_version: 1.2.3.4\n', '');
    file('pubspec.yaml').writeAsStringSync(pubspec);
    final result = await run(['Fixed the guide']);
    expect(result.exitCode, isNot(0));
    expect(file('pubspec.yaml').readAsStringSync(), pubspec);
    expect(file('CHANGELOG.md').readAsStringSync(),
        '# Changelog\n\n## Build 4\n');
  });
}
