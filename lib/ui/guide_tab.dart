import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/xtream_client.dart';
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

const _pxPerMinute = 4.5;
const _nameWidth = 208.0;
const _rowHeight = 76.0;
const _rulerHeight = 44.0;
const _window = Duration(hours: 12);
const _timelineWidth = 12 * 60 * _pxPerMinute;

/// Names and programmes are two lazy lists scrolled as one, so channel names
/// stay pinned while the timeline moves sideways.
class GuideTab extends ConsumerStatefulWidget {
  const GuideTab({super.key});

  @override
  ConsumerState<GuideTab> createState() => _GuideTabState();
}

class _GuideTabState extends ConsumerState<GuideTab> {
  final _names = ScrollController();
  final _rows = ScrollController();
  final _timeline = ScrollController();
  bool _mirroring = false;
  String? _picked;

  @override
  void initState() {
    super.initState();
    _names.addListener(() => _mirror(_names, _rows));
    _rows.addListener(() => _mirror(_rows, _names));
  }

  void _mirror(ScrollController from, ScrollController to) {
    if (_mirroring || !to.hasClients) return;
    _mirroring = true;
    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));
    _mirroring = false;
  }

  @override
  void dispose() {
    _names.dispose();
    _rows.dispose();
    _timeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(minuteProvider);
    final categories =
        ref.watch(categoriesProvider(CategoryKind.live)).value ?? const [];
    final categoryId = pickCategory(_picked, categories);
    final rows = ref.watch(browseProvider((
      kind: CategoryKind.live,
      categoryId: categoryId,
      search: '',
    )));
    final channels =
        (rows.value ?? const []).cast<PlaylistChannel>().toList();

    final now = DateTime.now();
    // Whole hours, so row provider keys only change once an hour.
    final from = DateTime(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(minutes: 30));
    final nowX = now.difference(from).inSeconds / 60 * _pxPerMinute;
    final noScrollbars =
        ScrollConfiguration.of(context).copyWith(scrollbars: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Guide', style: heading(28)),
          const SizedBox(height: 20),
          CategoryChips(
            kind: CategoryKind.live,
            value: categoryId,
            includeFavorites: true,
            onChanged: (id) => setState(() => _picked = id),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: OnAir.panel,
                border: Border.all(color: OnAir.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: _nameWidth,
                    child: Column(
                      children: [
                        const _RulerCell(label: 'Today', edge: false),
                        Expanded(
                          child: ScrollConfiguration(
                            behavior: noScrollbars,
                            child: ListView.builder(
                              controller: _names,
                              itemExtent: _rowHeight,
                              itemCount: channels.length,
                              itemBuilder: (context, i) =>
                                  _NameCell(channel: channels[i], all: channels),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: _timeline,
                      child: SingleChildScrollView(
                        controller: _timeline,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: _timelineWidth,
                          child: Stack(
                            children: [
                              Column(
                                children: [
                                  SizedBox(
                                    height: _rulerHeight,
                                    child: Row(
                                      children: [
                                        for (var h = 0; h < 12; h++)
                                          SizedBox(
                                            width: 60 * _pxPerMinute,
                                            child: _RulerCell(
                                              label: clock(from
                                                  .add(Duration(hours: h))),
                                              edge: true,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: ScrollConfiguration(
                                      behavior: noScrollbars,
                                      child: ListView.builder(
                                        controller: _rows,
                                        itemExtent: _rowHeight,
                                        itemCount: channels.length,
                                        itemBuilder: (context, i) => _Timeline(
                                          channel: channels[i],
                                          all: channels,
                                          from: from,
                                          now: now,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (nowX >= 0 && nowX <= _timelineWidth) ...[
                                Positioned(
                                  left: nowX,
                                  top: 0,
                                  bottom: 0,
                                  width: 2,
                                  child: const IgnorePointer(
                                    child: ColoredBox(color: OnAir.accent),
                                  ),
                                ),
                                Positioned(
                                  left: nowX - 26,
                                  top: 9,
                                  child: IgnorePointer(
                                    child: Container(
                                      width: 54,
                                      height: 26,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: OnAir.accent,
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      child: Text(
                                        clock(now),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: OnAir.accentInk,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RulerCell extends StatelessWidget {
  const _RulerCell({required this.label, required this.edge});

  final String label;
  final bool edge;

  @override
  Widget build(BuildContext context) {
    const side = BorderSide(color: OnAir.line);
    return Container(
      height: _rulerHeight,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.only(left: edge ? 10 : 16),
      decoration: BoxDecoration(
        border: Border(bottom: side, left: edge ? side : BorderSide.none),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 13, color: OnAir.muted)),
    );
  }
}

class _NameCell extends ConsumerWidget {
  const _NameCell({required this.channel, required this.all});

  final PlaylistChannel channel;
  final List<PlaylistChannel> all;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OnAir.line)),
      ),
      // Its own Material: ink would hide behind the opaque panel.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => openChannel(context, ref, channel, playlist: all),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            child: Row(
              children: [
                ChannelLogo(
                    name: channel.name,
                    url: channel.logoUrl,
                    size: 40,
                    radius: 9),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(channel.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (channel.archiveDays > 0)
                  IconButton(
                    tooltip: 'Catch up on ${channel.name}',
                    icon: const Icon(Icons.history,
                        size: 20, color: OnAir.muted),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => _CatchUpSheet(channel: channel),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Past programmes the provider still has. Limited by the guide itself, which
/// keeps about a day of history.
class _CatchUpSheet extends ConsumerWidget {
  const _CatchUpSheet({required this.channel});

  final PlaylistChannel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final past = ref.watch(epgRowProvider((
      key: channel.epgKey,
      from: now.subtract(Duration(days: channel.archiveDays)),
      to: DateTime(now.year, now.month, now.day, now.hour, now.minute),
    )));
    final programs = (past.value ?? const <EpgProgram>[])
        .where((p) => canCatchUp(channel, p, now))
        .toList()
        .reversed
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Catch up on ${channel.name}', style: heading(22)),
          const SizedBox(height: 12),
          Expanded(
            child: programs.isEmpty
                ? const EmptyMessage('No past programmes in the guide')
                : ListView.builder(
                    itemCount: programs.length,
                    itemBuilder: (context, i) {
                      final p = programs[i];
                      return ListTile(
                        title: Text(p.title, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${clock(p.startTime)} – ${clock(p.stopTime)}'),
                        onTap: () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          openCatchUp(navigator.context, ref, channel, p);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends ConsumerWidget {
  const _Timeline({
    required this.channel,
    required this.all,
    required this.from,
    required this.now,
  });

  final PlaylistChannel channel;
  final List<PlaylistChannel> all;
  final DateTime from;
  final DateTime now;

  /// Clamped, as programmes may start before or end after the window.
  double _x(DateTime t) =>
      t.difference(from).inMinutes.clamp(0, _window.inMinutes) * _pxPerMinute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final programs = ref
        .watch(epgRowProvider(
            (key: channel.epgKey, from: from, to: from.add(_window))))
        .value;
    final reminders = ref.watch(remindersProvider).value ?? const [];
    bool reminded(EpgProgram p) => reminders.any((r) =>
        r.channelId == channel.id && r.startTime.isAtSameMomentAs(p.startTime));

    void remind(EpgProgram p) {
      final db = ref.read(databaseProvider);
      final on = !reminded(p);
      on ? db.addReminder(channel.id, p)
          : db.removeReminder(channel.id, p.startTime);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(on
              ? "We'll remind you before ${p.title}"
              : 'Reminder removed'),
        ));
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OnAir.line)),
      ),
      child: Stack(
        children: [
          if (programs != null && programs.isEmpty)
            const Positioned(
              left: 6,
              top: 6,
              bottom: 6,
              width: 420,
              child: _NoGuide(),
            ),
          for (final p in programs ?? const <EpgProgram>[])
            Positioned(
              left: _x(p.startTime),
              width: _x(p.stopTime) - _x(p.startTime),
              top: 6,
              bottom: 6,
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: _Block(
                  program: p,
                  airing: p.startTime.isBefore(now) && p.stopTime.isAfter(now),
                  badge: reminded(p)
                      ? Icons.notifications_active
                      : canCatchUp(channel, p, now)
                          ? Icons.history
                          : null,
                  onTap: () {
                    if (p.startTime.isAfter(now)) {
                      remind(p);
                    } else if (canCatchUp(channel, p, now)) {
                      openCatchUp(context, ref, channel, p);
                    } else {
                      openChannel(context, ref, channel, playlist: all);
                    }
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoGuide extends StatelessWidget {
  const _NoGuide();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: OnAir.fieldLine),
      ),
      child: const Text('No guide data for this channel',
          style: TextStyle(fontSize: 13, color: OnAir.muted)),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.program,
    required this.airing,
    required this.badge,
    required this.onTap,
  });

  final EpgProgram program;
  final bool airing;
  final IconData? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: airing ? OnAir.airing : OnAir.raised,
      borderRadius: BorderRadius.circular(9),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  if (badge case final icon?) ...[
                    Icon(icon, size: 14, color: OnAir.accent),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      program.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: airing ? OnAir.accentText : OnAir.text,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${clock(program.startTime)} – ${clock(program.stopTime)}',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 12,
                  color: airing ? const Color(0xFFE8C47A) : OnAir.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
