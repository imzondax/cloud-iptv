import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'failover.dart';

/// Trades channel change speed against riding out a shaky connection. On a
/// stream arriving in real time, playback starts about 1s, 2s and 3s in.
enum BufferProfile {
  small(fillFirst: false, resumeSeconds: 1),
  medium(fillFirst: true, resumeSeconds: 2),
  large(fillFirst: true, resumeSeconds: 4);

  const BufferProfile({required this.fillFirst, required this.resumeSeconds});

  /// Whether to wait for [resumeSeconds] of video before the first frame.
  final bool fillFirst;

  /// Video to hold before resuming after the buffer runs dry.
  final int resumeSeconds;
}

/// libmpv tuned for unreliable IPTV links, plus retry and failover.
class IptvPlayer {
  IptvPlayer({
    required bool hardwareAcceleration,
    BufferProfile buffer = BufferProfile.medium,
    double volume = 100,
  }) {
    _ready = _configure(hardwareAcceleration, buffer, volume);
    _subscriptions = [
      player.stream.position.listen(_onPosition),
      player.stream.error.listen((_) => _onError()),
      player.stream.completed.listen(_onCompleted),
      player.stream.playing.listen(_onPlaying),
      player.stream.buffering.listen((_) => _updateBuffering()),
      player.stream.buffer.listen((_) => _updateBuffering()),
    ];
  }

  /// Sets mpv's demuxer cache, forward and back.
  static const _cacheBytes = 64 * 1024 * 1024;
  static const _healthyAfter = Duration(seconds: 10);
  static const _connectTimeout = Duration(seconds: 20);
  static const _stallTimeout = Duration(seconds: 15);

  /// Grace period after an mpv error. Decoder errors are routine on IPTV (one
  /// corrupt frame logs one), so only an error that stops playback counts.
  static const _errorGrace = Duration(seconds: 3);

  final Player player = Player(
    configuration: const PlayerConfiguration(
      title: 'Cloud IPTV',
      bufferSize: _cacheBytes,
    ),
  );
  late final VideoController video = VideoController(player);

  final ValueNotifier<bool> buffering = ValueNotifier(false);

  /// User-facing state of the failover logic, null while all is well.
  final ValueNotifier<String?> notice = ValueNotifier(null);

  /// True once every URL has failed.
  final ValueNotifier<bool> failed = ValueNotifier(false);

  late final Future<void> _ready;
  late final List<StreamSubscription<Object?>> _subscriptions;
  final BufferGauge _gauge = BufferGauge();

  FailoverPolicy? _policy;
  List<String> _urls = const [];
  bool _live = false;
  bool _reopening = false;
  Timer? _watchdog;
  Duration? _healthyAt;
  Duration _lastPosition = Duration.zero;

  NativePlayer get _mpv => player.platform as NativePlayer;

  Future<void> _configure(
      bool hardwareAcceleration, BufferProfile buffer, double volume) async {
    // A stream opened before this attaches sits at 0:00 until the connect
    // timeout, and channels are opened before the video view exists.
    await video.platform.future;
    await _mpv.setProperty('cache-secs', '30');
    await _mpv.setProperty('demuxer-readahead-secs', '5');
    await _mpv.setProperty('network-timeout', '10');
    await _applyBuffer(buffer);
    await setHardwareAcceleration(hardwareAcceleration);
    await player.setVolume(volume);
  }

  /// Tracks to prefer, as mpv's comma separated language codes.
  Future<void> setLanguages({required String audio, required String subtitles}) async {
    await _ready;
    await _mpv.setProperty('alang', audio);
    await _mpv.setProperty('slang', subtitles);
  }

  Future<void> setBufferProfile(BufferProfile profile) async {
    // Startup would otherwise overwrite this with the initial profile.
    await _ready;
    await _applyBuffer(profile);
  }

  Future<void> _applyBuffer(BufferProfile profile) async {
    await _mpv.setProperty(
        'cache-pause-initial', profile.fillFirst ? 'yes' : 'no');
    await _mpv.setProperty('cache-pause-wait', '${profile.resumeSeconds}');
  }

  Future<void> setHardwareAcceleration(bool enabled) =>
      _mpv.setProperty('hwdec', enabled ? 'auto-safe' : 'no');

  /// A movie begins at [start], if given.
  Future<void> open(List<String> urls,
      {required bool live, Duration? start}) async {
    await _ready;
    _urls = urls;
    _policy = FailoverPolicy(urls);
    _live = live;
    _lastPosition = start ?? Duration.zero;
    notice.value = null;
    failed.value = false;
    await _load();
  }

  Future<void> retry() => open(_urls, live: _live, start: _lastPosition);

  Future<void> stop() async {
    _policy = null;
    _watchdog?.cancel();
    buffering.value = false;
    notice.value = null;
    failed.value = false;
    await player.stop();
  }

  Future<void> _load() async {
    final policy = _policy;
    if (policy == null) return;
    _healthyAt = null;
    _arm(_connectTimeout);
    _reopening = true;
    try {
      await player.open(Media(
        policy.currentUrl,
        // A reopened movie must not restart from the beginning.
        start: _live || _lastPosition == Duration.zero ? null : _lastPosition,
      ));
    } finally {
      _reopening = false;
    }
  }

  void _arm(Duration timeout) {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, _onFailure);
  }

  void _onPosition(Duration position) {
    if (_policy == null || _reopening || position == _lastPosition) return;
    if (position == Duration.zero) return;
    _lastPosition = position;
    _arm(_stallTimeout);
    _updateBuffering();
    final healthyAt = _healthyAt ??= position + _healthyAfter;
    if (position >= healthyAt) {
      _policy!.onHealthy();
      notice.value = null;
    }
  }

  void _onError() {
    if (_policy != null && !_reopening) _arm(_errorGrace);
  }

  void _onCompleted(bool completed) {
    // A live stream has no end, so reaching one means the connection dropped.
    if (completed && _live && !_reopening) _onFailure();
    if (completed && !_live) _watchdog?.cancel();
  }

  void _onPlaying(bool playing) {
    if (_policy == null || _reopening) return;
    // A user pause must not read as a stall.
    playing ? _arm(_stallTimeout) : _watchdog?.cancel();
  }

  void _updateBuffering() {
    final state = player.state;
    final ahead = state.buffer - state.position;
    // The last seconds of a movie have nothing left to buffer.
    final nearEnd = !_live &&
        state.duration > Duration.zero &&
        state.duration - state.position < _gauge.highWater;
    final low = _healthyAt != null && !nearEnd && _gauge.update(ahead);
    buffering.value = state.buffering || low;
  }

  void _onFailure() {
    final policy = _policy;
    if (policy == null) return;
    _watchdog?.cancel();
    switch (policy.onFailure()) {
      case FailoverAction.retry:
        notice.value = 'Reconnecting…';
        Timer(Duration(seconds: policy.failures), () {
          if (identical(policy, _policy)) _load();
        });
      case FailoverAction.switchUrl:
        notice.value = 'Switching to a backup stream…';
        _load();
      case FailoverAction.giveUp:
        notice.value = 'This stream is unavailable.';
        failed.value = true;
        buffering.value = false;
        _policy = null;
        player.stop();
    }
  }

  Future<void> dispose() async {
    _watchdog?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    buffering.dispose();
    notice.dispose();
    failed.dispose();
    await player.dispose();
  }
}
