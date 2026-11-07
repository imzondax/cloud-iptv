// Drives the real libmpv against a local stream server. Run on Windows with:
//   flutter test integration_test/player_test.dart -d windows
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cloud_iptv/models/models.dart';
import 'package:cloud_iptv/player/iptv_player.dart';
import 'package:cloud_iptv/player/player_view.dart';
import 'package:cloud_iptv/providers/providers.dart';
import 'package:cloud_iptv/services/database.dart';
import 'package:cloud_iptv/ui/player_screen.dart';
import 'package:cloud_iptv/ui/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

/// 50s of Big Buck Bunny (CC BY 3.0, Blender Foundation) as H.264/AAC MPEG-TS.
const _sample = 'integration_test/fixtures/sample.ts';
const _sampleSeconds = 50;
const _tick = Duration(milliseconds: 100);

/// Replays the sample like an IPTV server: an initial burst, then real time.
class StreamServer {
  late final HttpServer _server;
  late final Uint8List _bytes;
  final hits = <String, int>{};

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';
  int count(String path) => hits[path] ?? 0;

  Future<void> start() async {
    _bytes = await File(_sample).readAsBytes();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    hits[path] = count(path) + 1;
    final response = request.response;
    if (path == '/dead') {
      response.statusCode = 404;
      await response.close();
      return;
    }
    response.bufferOutput = false;
    response.headers.contentType = ContentType('video', 'mp2t');
    final perSecond = _bytes.length ~/ _sampleSeconds ~/ 188 * 188;
    final perTick = perSecond ~/ 10 ~/ 188 * 188;
    // /stall hangs with the socket open, /drop closes it, /live keeps going.
    // /paced is /live with no burst, like a busy provider.
    final paced = path == '/paced';
    final end = path == '/live' || paced ? _bytes.length : perSecond * 8;
    final burst = paced ? perTick : perSecond * 5;
    try {
      response.add(Uint8List.sublistView(_bytes, 0, burst));
      await response.flush();
      for (var i = burst; i + perTick <= end; i += perTick) {
        response.add(Uint8List.sublistView(_bytes, i, i + perTick));
        await response.flush();
        await Future<void>.delayed(_tick);
      }
      if (path == '/stall') await Completer<void>().future;
      await response.close();
    } catch (_) {
      // The player hung up.
    }
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late StreamServer server;
  late IptvPlayer player;

  Future<void> until(WidgetTester tester, bool Function() done,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    await until(tester, () => DateTime.now().isAfter(end),
        timeout: d + const Duration(seconds: 1));
  }

  Duration position() => player.player.state.position;

  Future<void> setUpPlayer(WidgetTester tester) async {
    server = StreamServer();
    await server.start();
    player = IptvPlayer(hardwareAcceleration: true);
    await tester.pumpWidget(MaterialApp(home: IptvPlayerView(player: player)));
    addTearDown(() async {
      await player.dispose();
      await server.stop();
    });
  }

  testWidgets('plays a live stream without tripping failover', (tester) async {
    await setUpPlayer(tester);
    await player.open([server.url('/live')], live: true);
    await until(tester, () => position() > const Duration(seconds: 12));
    expect(server.count('/live'), 1);
    expect(player.notice.value, isNull);
    expect(player.player.state.width, greaterThan(0));
    // ignore: avoid_print
    print('hwdec-current=${await (player.player.platform as NativePlayer).getProperty('hwdec-current')}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a dead URL fails 3 times, then the backup plays',
      (tester) async {
    await setUpPlayer(tester);
    await player.open([server.url('/dead'), server.url('/live')], live: true);
    await until(tester, () => position() > const Duration(seconds: 12));
    expect(server.count('/dead'), 3);
    expect(server.count('/live'), 1);
    expect(player.notice.value, isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('gives up with a message when every URL is dead', (tester) async {
    await setUpPlayer(tester);
    await player.open([server.url('/dead')], live: true);
    await until(tester, () => player.notice.value == 'This stream is unavailable.');
    expect(server.count('/dead'), 3);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a stalled stream shows buffering, then fails over',
      (tester) async {
    await setUpPlayer(tester);
    var sawBuffering = false;
    player.buffering.addListener(() {
      if (player.buffering.value && position() > Duration.zero) {
        sawBuffering = true;
      }
    });
    await player.open([server.url('/stall'), server.url('/live')], live: true);
    await until(tester, () => server.count('/live') > 0,
        timeout: const Duration(minutes: 3));
    expect(server.count('/stall'), 3);
    expect(sawBuffering, isTrue);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('a dropped live connection reconnects', (tester) async {
    await setUpPlayer(tester);
    await player.open([server.url('/drop'), server.url('/live')], live: true);
    await until(tester, () => server.count('/drop') >= 2,
        timeout: const Duration(minutes: 1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a user pause is not treated as a stall', (tester) async {
    await setUpPlayer(tester);
    await player.open([server.url('/live')], live: true);
    await until(tester, () => position() > const Duration(seconds: 2));
    await player.player.pause();
    await wait(tester, const Duration(seconds: 18));
    expect(server.count('/live'), 1);
    expect(player.notice.value, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('smaller buffers start a slow stream sooner', (tester) async {
    await setUpPlayer(tester);
    final started = <BufferProfile, int>{};
    for (final profile in BufferProfile.values) {
      await player.setBufferProfile(profile);
      final watch = Stopwatch()..start();
      await player.open([server.url('/paced')], live: true);
      await until(tester, () => position() > Duration.zero,
          timeout: const Duration(seconds: 15));
      started[profile] = watch.elapsedMilliseconds;
      await player.stop();
      await wait(tester, const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('first frame: $started');
    expect(started[BufferProfile.small], lessThan(2000));
    expect(started[BufferProfile.small]!,
        lessThan(started[BufferProfile.medium]!));
    expect(started[BufferProfile.medium]!,
        lessThan(started[BufferProfile.large]!));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a movie resumes where it was left, and finishing clears it',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final item = VodItem(
      id: '1:movie',
      sourceId: 1,
      title: 'Sample',
      streamUrl: File(_sample).absolute.path,
      categoryId: 'c',
      sortOrder: 0,
    );
    final active = container.read(activeStreamProvider.notifier);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PlayerScreen()),
    ));

    // Riverpod delivers on frames, so frames must run during these calls.
    Future<void> pumping(Future<void> call) async {
      var done = false;
      unawaited(call.whenComplete(() => done = true));
      await until(tester, () => done);
      await call;
    }

    await pumping(active.playVod(item));
    player = await tester.runAsync(() => container.read(playerProvider.future))
        as IptvPlayer;
    await until(tester, () => position() > const Duration(seconds: 1));
    await player.player.seek(const Duration(seconds: 35));
    await until(tester, () => position() > const Duration(seconds: 35));
    await pumping(active.stop());
    final saved = await db.progress(item.id);
    expect(saved, greaterThan(const Duration(seconds: 34)));
    expect(await db.watchKeepWatching(5).first, hasLength(1));

    // Otherwise the check below could pass on the old position.
    await until(tester, () => position() < const Duration(seconds: 1));
    await pumping(active.playVod(item));
    await until(tester, () => position() > const Duration(seconds: 34),
        timeout: const Duration(seconds: 10));

    await player.player.seek(const Duration(seconds: 49));
    await until(tester, () => position() > const Duration(seconds: 48));
    await pumping(active.stop());
    expect(await db.progress(item.id), isNull);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('the player screen drives playback end to end', (tester) async {
    server = StreamServer();
    await server.start();
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(() async {
      container.dispose();
      await db.close();
      await server.stop();
    });
    PlaylistChannel channel(String name, String path) => PlaylistChannel(
          id: name,
          sourceId: 1,
          name: name,
          streamUrl: server.url(path),
          categoryId: 'c',
          backendType: BackendType.m3u,
          sortOrder: 0,
        );
    final channels = [channel('Good', '/live'), channel('Broken', '/dead')];
    final boundary = GlobalKey();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: onAirTheme(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    openChannel(context, ref, channels.first, playlist: channels),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ));
    Future<void> shot(String name) async {
      final dir = Platform.environment['SHOT_DIR'];
      if (dir == null) return;
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await render.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await tester.tap(find.text('go'));
    await until(tester, () => find.byType(PlayerScreen).evaluate().isNotEmpty);
    player = await tester.runAsync(() => container.read(playerProvider.future))
        as IptvPlayer;
    await until(tester, () => position() > const Duration(seconds: 1));
    expect(find.text('Good'), findsOneWidget);

    double overlay() => tester
        .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
        .opacity;
    await until(tester, () => overlay() == 0,
        timeout: const Duration(seconds: 6));

    // A tap brings the controls back, and they work.
    await tester.tapAt(tester.getCenter(find.byType(PlayerScreen)));
    await wait(tester, const Duration(milliseconds: 500));
    expect(overlay(), 1);
    await shot('player-controls');
    // A healthy stream connects once and never claims to be reconnecting.
    expect(server.count('/live'), 1);
    expect(player.notice.value, isNull);
    await tester.tap(find.byTooltip('Pause'));
    await until(tester, () => !player.player.state.playing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await until(tester, () => player.player.state.playing);

    // Next channel is dead, so failover gives up and offers a retry.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await until(tester, () => find.text('Try again').evaluate().isNotEmpty);
    expect(find.text('Broken'), findsOneWidget);
    expect(server.count('/dead'), 3);
    await shot('player-unavailable');

    await tester.tap(find.text('Try again'));
    await until(tester, () => server.count('/dead') > 3);
    await until(tester, () => find.text('Try again').evaluate().isNotEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await until(tester, () => find.byType(PlayerScreen).evaluate().isEmpty);
    await until(tester, () => container.read(activeStreamProvider) == null);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
