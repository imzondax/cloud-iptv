import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../player/iptv_player.dart';
import '../player/player_view.dart';
import '../providers/providers.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> openChannel(
    BuildContext context, WidgetRef ref, PlaylistChannel channel,
    {required List<PlaylistChannel> playlist}) {
  ref
      .read(activeStreamProvider.notifier)
      .playChannel(channel, playlist: playlist);
  return _push(context);
}

Future<void> openVod(BuildContext context, WidgetRef ref, VodItem item) {
  ref.read(activeStreamProvider.notifier).playVod(item);
  return _push(context);
}

Future<void> _push(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PlayerScreen()));

/// `h:mm:ss`, or `m:ss` under an hour.
String formatPosition(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final seconds = two(d.inSeconds % 60);
  final minutes = d.inMinutes % 60;
  return d.inHours > 0
      ? '${d.inHours}:${two(minutes)}:$seconds'
      : '$minutes:$seconds';
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  static const _hideAfter = Duration(seconds: 3);

  // ref is unusable in dispose, so hold on to the controller.
  late final ActiveStream _active = ref.read(activeStreamProvider.notifier);
  Timer? _hideTimer;
  bool _controls = true;
  bool _drawer = false;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _active;
    _wake();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_fullscreen) defaultExitNativeFullscreen();
    // Providers may not change while the tree is being torn down.
    Future.microtask(_active.stop);
    super.dispose();
  }

  void _wake() {
    if (!_controls) setState(() => _controls = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideAfter, () {
      if (mounted && !_drawer) setState(() => _controls = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    final enter = !_fullscreen;
    setState(() => _fullscreen = enter);
    await (enter ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
  }

  void _escape() {
    if (_fullscreen) {
      _toggleFullscreen();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _step(int delta) {
    _active.step(delta);
    _wake();
  }

  @override
  Widget build(BuildContext context) {
    final playing = ref.watch(activeStreamProvider);
    final player = ref.watch(playerProvider);
    final channel = playing?.channel;
    final canStep = (playing?.playlist.length ?? 0) > 1;

    final Widget body = switch (player) {
      AsyncData(:final value) => Stack(
          fit: StackFit.expand,
          children: [
            IptvPlayerView(player: value),
            _Fade(
              visible: _controls,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    title: playing?.title ?? '',
                    channel: channel,
                    onBack: () => Navigator.of(context).maybePop(),
                  ),
                  _BottomBar(
                    player: value,
                    channel: channel,
                    canStep: canStep,
                    drawerOpen: _drawer,
                    fullscreen: _fullscreen,
                    onStep: _step,
                    onDrawer: () => setState(() {
                      _drawer = !_drawer;
                      _wake();
                    }),
                    onFullscreen: _toggleFullscreen,
                  ),
                ],
              ),
            ),
            if (_drawer && playing != null)
              Align(
                alignment: Alignment.centerRight,
                child: _ChannelDrawer(
                  playing: playing,
                  onClose: () => setState(() => _drawer = false),
                  onPick: (c) => _active.playChannel(c),
                ),
              ),
            ValueListenableBuilder(
              valueListenable: value.failed,
              builder: (context, failed, _) => failed
                  ? _Unavailable(
                      onBack: () => Navigator.of(context).maybePop(),
                      onRetry: value.retry,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      AsyncError() =>
        const EmptyMessage('Could not start the player'),
      _ => const Center(child: CircularProgressIndicator()),
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            player.value?.player.playOrPause();
            _wake();
          },
          const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
          if (canStep) ...{
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(-1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(1),
          },
        },
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            cursor: _controls ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _wake(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_controls) {
                  setState(() => _controls = false);
                } else {
                  _wake();
                }
              },
              onDoubleTap: _toggleFullscreen,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _Fade extends StatelessWidget {
  const _Fade({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: child,
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: Colors.white,
        backgroundColor: selected ? OnAir.accentSoft : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Icon(icon, size: 22, color: selected ? OnAir.accent : Colors.white),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.title,
    required this.channel,
    required this.onBack,
  });

  final String title;
  final PlaylistChannel? channel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final program = c == null ? null : ref.watch(currentProgramProvider(c)).value;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 56),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xC8000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              backgroundColor: const Color(0xCC0E1116),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 14),
          if (c != null) ...[
            ChannelLogo(name: c.name, url: c.logoUrl, size: 44),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis, style: heading(20)),
                if (program != null) ...[
                  const SizedBox(height: 2),
                  Text(program.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFD5DBE3))),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.player,
    required this.channel,
    required this.canStep,
    required this.drawerOpen,
    required this.fullscreen,
    required this.onStep,
    required this.onDrawer,
    required this.onFullscreen,
  });

  final IptvPlayer player;
  final PlaylistChannel? channel;
  final bool canStep;
  final bool drawerOpen;
  final bool fullscreen;
  final ValueChanged<int> onStep;
  final VoidCallback onDrawer;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final mpv = player.player;
    final live = channel != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xD9000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (channel case final c?)
            _ProgramBar(channel: c)
          else
            _SeekBar(player: mpv),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canStep)
                    _RoundButton(
                      tooltip: 'Previous channel',
                      icon: Icons.skip_previous_rounded,
                      onPressed: () => onStep(-1),
                    ),
                  const SizedBox(width: 6),
                  StreamBuilder(
                    stream: mpv.stream.playing,
                    initialData: mpv.state.playing,
                    builder: (context, snapshot) {
                      final isPlaying = snapshot.data ?? false;
                      return IconButton(
                        tooltip: isPlaying ? 'Pause' : 'Play',
                        onPressed: mpv.playOrPause,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(56, 56),
                          backgroundColor: OnAir.accent,
                          shape: const CircleBorder(),
                        ),
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          color: OnAir.accentInk,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  if (canStep)
                    _RoundButton(
                      tooltip: 'Next channel',
                      icon: Icons.skip_next_rounded,
                      onPressed: () => onStep(1),
                    ),
                  if (live) ...[
                    const SizedBox(width: 10),
                    const LivePill(),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Volume(player: mpv),
                  _TracksButton(player: mpv),
                  if (canStep)
                    _RoundButton(
                      tooltip: 'Channel list',
                      icon: Icons.menu,
                      selected: drawerOpen,
                      onPressed: onDrawer,
                    ),
                  _RoundButton(
                    tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
                    icon:
                        fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    onPressed: onFullscreen,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Progress through the current programme. Absent without guide data.
class _ProgramBar extends ConsumerWidget {
  const _ProgramBar({required this.channel});

  final PlaylistChannel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(minuteProvider);
    final program = ref.watch(currentProgramProvider(channel)).value;
    if (program == null) return const SizedBox.shrink();
    const style = TextStyle(fontSize: 13, color: Color(0xFFD5DBE3));
    return Row(
      children: [
        Text(clock(program.startTime), style: style),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progressOf(program, DateTime.now()),
              minHeight: 4,
              backgroundColor: const Color(0x40FFFFFF),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(clock(program.stopTime), style: style),
      ],
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});

  final Player player;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    const style = TextStyle(fontSize: 13, color: Color(0xFFD5DBE3));
    return StreamBuilder(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snapshot) {
        final total = player.state.duration;
        if (total <= Duration.zero) return const SizedBox.shrink();
        final position = snapshot.data ?? Duration.zero;
        final value = _dragging ??
            position.inMilliseconds.clamp(0, total.inMilliseconds).toDouble();
        return Row(
          children: [
            Text(formatPosition(Duration(milliseconds: value.toInt())),
                style: style),
            Expanded(
              child: Slider(
                semanticFormatterCallback: (v) =>
                    formatPosition(Duration(milliseconds: v.toInt())),
                value: value,
                max: total.inMilliseconds.toDouble(),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  player.seek(Duration(milliseconds: v.toInt()));
                  setState(() => _dragging = null);
                },
              ),
            ),
            Text(formatPosition(total), style: style),
          ],
        );
      },
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snapshot) {
        final volume = (snapshot.data ?? 100).clamp(0.0, 100.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(volume == 0 ? Icons.volume_off : Icons.volume_up,
                size: 20, color: Colors.white),
            SizedBox(
              width: 120,
              child: Slider(
                semanticFormatterCallback: (v) => 'Volume ${v.round()}%',
                value: volume,
                max: 100,
                onChanged: player.setVolume,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TracksButton extends StatelessWidget {
  const _TracksButton({required this.player});

  final Player player;

  String _label(String id, String? title, String? language) => switch (id) {
        'auto' => 'Automatic',
        'no' => 'Off',
        _ => title ?? language ?? 'Track $id',
      };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Audio and subtitles',
      onSelected: (select) => select(),
      icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
      itemBuilder: (context) {
        final tracks = player.state.tracks;
        final current = player.state.track;
        const header = TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: OnAir.muted);
        return [
          const PopupMenuItem(enabled: false, child: Text('Audio', style: header)),
          for (final t in tracks.audio)
            CheckedPopupMenuItem(
              value: () => player.setAudioTrack(t),
              checked: t == current.audio,
              child: Text(_label(t.id, t.title, t.language)),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
              enabled: false, child: Text('Subtitles', style: header)),
          for (final t in tracks.subtitle)
            CheckedPopupMenuItem(
              value: () => player.setSubtitleTrack(t),
              checked: t == current.subtitle,
              child: Text(_label(t.id, t.title, t.language)),
            ),
        ];
      },
    );
  }
}

class _ChannelDrawer extends StatelessWidget {
  const _ChannelDrawer({
    required this.playing,
    required this.onClose,
    required this.onPick,
  });

  final NowPlaying playing;
  final VoidCallback onClose;
  final ValueChanged<PlaylistChannel> onPick;

  @override
  Widget build(BuildContext context) {
    final channels = playing.playlist;
    return Container(
      width: 340,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xF20E1116),
        border: Border(left: BorderSide(color: OnAir.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              Expanded(child: Text('Channels', style: heading(20))),
              IconButton(
                tooltip: 'Close channel list',
                onPressed: onClose,
                icon: const Icon(Icons.close, color: OnAir.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: channels.length,
              itemExtent: 64,
              itemBuilder: (context, i) => _DrawerRow(
                channel: channels[i],
                selected: channels[i].id == playing.channel?.id,
                onTap: () => onPick(channels[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerRow extends ConsumerWidget {
  const _DrawerRow({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final PlaylistChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final program = ref.watch(scheduleProvider(channel.epgKey)).value?.now;
    return Material(
      color: selected ? OnAir.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ChannelLogo(
                  name: channel.name, url: channel.logoUrl, size: 44, radius: 9),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(channel.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (program != null)
                      Text(program.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: OnAir.muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onBack, required this.onRetry});

  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xB8000000),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: OnAir.panel,
            border: Border.all(color: OnAir.line),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('This stream is unavailable',
                  textAlign: TextAlign.center, style: heading(22)),
              const SizedBox(height: 12),
              const Text(
                'We tried every backup for this channel. The provider may be '
                'down.',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.5, color: OnAir.muted),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(onPressed: onBack, child: const Text('Back')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: onRetry, child: const Text('Try again')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
