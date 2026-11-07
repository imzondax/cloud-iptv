import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/database.dart';
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class LiveTab extends ConsumerStatefulWidget {
  const LiveTab({super.key});

  @override
  ConsumerState<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends ConsumerState<LiveTab> {
  String? _picked;
  String _search = '';
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(categoriesProvider(CategoryKind.live)).value ?? const [];
    final categoryId = _picked ?? categories.firstOrNull?.id;
    final rows = ref.watch(browseProvider((
      kind: CategoryKind.live,
      categoryId: categoryId,
      search: _search,
    )));
    final channels =
        (rows.value ?? const []).cast<PlaylistChannel>().toList();
    final selected = channels.where((c) => c.id == _selectedId).firstOrNull ??
        channels.firstOrNull;

    void pick(String id) => setState(() => _picked = id);
    void play(PlaylistChannel c) =>
        openChannel(context, ref, c, playlist: channels);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final showPreview = width >= 1100;
      final list = _ChannelList(
        channels: channels,
        loading: rows.isLoading && rows.value == null,
        selectedId: showPreview ? selected?.id : null,
        onSearch: (v) => setState(() => _search = v),
        // Without the preview pane a tap has nothing to select.
        onTap: showPreview
            ? (c) => setState(() => _selectedId = c.id)
            : play,
        onPlay: play,
      );

      if (width < 760) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CategoryChips(
                kind: CategoryKind.live,
                value: categoryId,
                includeFavorites: true,
                onChanged: pick,
              ),
              const SizedBox(height: 12),
              Expanded(child: list),
            ],
          ),
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 264,
            child: _CategoryPane(
              categories: categories,
              value: categoryId,
              onChanged: pick,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
              child: list,
            ),
          ),
          if (showPreview)
            SizedBox(
              width: 368,
              child: selected == null
                  ? const ColoredBox(color: OnAir.panel)
                  : _PreviewPane(
                      channel: selected,
                      onWatch: () => play(selected),
                    ),
            ),
        ],
      );
    });
  }
}

class _CategoryPane extends ConsumerWidget {
  const _CategoryPane({
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  final List<Category> categories;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(categoryCountsProvider).value ?? const {};
    final favorites = ref.watch(favoriteIdsProvider).value?.length ?? 0;
    final rows = [
      (id: favoritesCategoryId, name: 'Favorites', count: favorites),
      for (final c in categories)
        (id: c.id, name: c.name, count: counts[c.id] ?? 0),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: OnAir.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 28, 16, 20),
            child: Text('Live TV', style: heading(28)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: rows.length,
              itemExtent: 46,
              itemBuilder: (context, i) {
                final row = rows[i];
                final selected = row.id == value;
                final color = selected ? OnAir.accent : OnAir.text;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Semantics(
                    selected: selected,
                    button: true,
                    child: Material(
                      color: selected ? OnAir.accentSoft : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => onChanged(row.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  row.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${row.count}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      selected ? OnAir.accent : OnAir.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.channels,
    required this.loading,
    required this.selectedId,
    required this.onSearch,
    required this.onTap,
    required this.onPlay,
  });

  final List<PlaylistChannel> channels;
  final bool loading;
  final String? selectedId;
  final ValueChanged<String> onSearch;
  final ValueChanged<PlaylistChannel> onTap;
  final ValueChanged<PlaylistChannel> onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SearchField(hint: 'Search channels', onChanged: onSearch),
        const SizedBox(height: 14),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : channels.isEmpty
                  ? const EmptyMessage(
                      'Nothing here yet. Add a source in Sources.')
                  : ListView.builder(
                      itemCount: channels.length,
                      itemExtent: 80,
                      itemBuilder: (context, i) {
                        final channel = channels[i];
                        return _ChannelRow(
                          channel: channel,
                          selected: channel.id == selectedId,
                          onTap: () => onTap(channel),
                          onDoubleTap: () => onPlay(channel),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _ChannelRow extends ConsumerWidget {
  const _ChannelRow({
    required this.channel,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
  });

  final PlaylistChannel channel;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorite = ref.watch(favoriteIdsProvider
        .select((ids) => ids.value?.contains(channel.id) ?? false));
    final program = ref.watch(scheduleProvider(channel.epgKey)).value?.now;
    final now = DateTime.now();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? OnAir.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                ChannelLogo(name: channel.name, url: channel.logoUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              channel.name,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (program != null)
                            Text(
                              timeLeft(program.stopTime, now),
                              style: const TextStyle(
                                  fontSize: 12, color: OnAir.muted),
                            ),
                        ],
                      ),
                      if (program != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          program.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: OnAir.muted),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progressOf(program, now),
                            minHeight: 3,
                            backgroundColor: OnAir.line,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: favorite
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  icon: Icon(
                    favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    color: favorite ? OnAir.accent : OnAir.muted,
                  ),
                  onPressed: () => ref
                      .read(databaseProvider)
                      .setFavorite(channel.id, !favorite),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPane extends ConsumerWidget {
  const _PreviewPane({required this.channel, required this.onWatch});

  final PlaylistChannel channel;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(scheduleProvider(channel.epgKey)).value;
    final program = schedule?.now;
    final next = schedule?.next.take(3).toList() ?? const <EpgProgram>[];

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: OnAir.panel,
        border: Border(left: BorderSide(color: OnAir.line)),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        children: [
          Container(
            height: 200,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: OnAir.raised,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ChannelLogo(
                    name: channel.name, url: channel.logoUrl, size: 72),
                const LivePill(),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            program == null ? 'Live now' : channel.name,
            style: const TextStyle(fontSize: 13, color: OnAir.muted),
          ),
          const SizedBox(height: 6),
          Text(program?.title ?? channel.name, style: heading(24)),
          if (program != null) ...[
            const SizedBox(height: 8),
            Text(
              '${clock(program.startTime)} – ${clock(program.stopTime)}',
              style: const TextStyle(fontSize: 13, color: OnAir.muted),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onWatch,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Watch now'),
          ),
          if (program?.description case final about?) ...[
            const SizedBox(height: 18),
            Text(about,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.55, color: OnAir.body)),
          ],
          if (next.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Up next',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: OnAir.muted)),
            const SizedBox(height: 10),
            for (final p in next)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: OnAir.line)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(clock(p.startTime),
                          style: const TextStyle(
                              fontSize: 13, color: OnAir.muted)),
                    ),
                    Expanded(
                      child: Text(p.title,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
