import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import 'library_tab.dart';
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class DashboardTab extends ConsumerStatefulWidget {
  const DashboardTab({super.key});

  @override
  ConsumerState<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends ConsumerState<DashboardTab> {
  String _search = '';

  Widget _titleCard(Object item) => SizedBox(
        width: 170,
        child: switch (item) {
          VodItem m => PosterCard(
              title: m.title,
              url: m.posterUrl,
              year: m.year,
              rating: m.rating,
              tv: false,
              onTap: () => openVod(context, ref, m),
            ),
          SeriesItem s => PosterCard(
              title: s.title,
              url: s.posterUrl,
              year: s.year,
              rating: s.rating,
              tv: true,
              onTap: () => showEpisodes(context, s),
            ),
          _ => const SizedBox.shrink(),
        },
      );

  Widget _titles(String title, List<Object> items) => _Shelf(
        key: ValueKey(title),
        title: title,
        height: 300,
        count: items.length,
        builder: (context, i) => _titleCard(items[i]),
      );

  List<Widget> _results() {
    List<Object> find(CategoryKind kind) =>
        ref
            .watch(browseProvider(
                (kind: kind, categoryId: null, search: _search)))
            .value ??
        const [];
    final channels = find(CategoryKind.live).cast<PlaylistChannel>().toList();
    final movies = find(CategoryKind.vod);
    final series = find(CategoryKind.series);
    if (channels.isEmpty && movies.isEmpty && series.isEmpty) {
      return [const EmptyMessage('Nothing matches your search')];
    }
    return [
      if (channels.isNotEmpty) _liveShelf('Channels', channels),
      if (movies.isNotEmpty) _titles('Movies', movies),
      if (series.isNotEmpty) _titles('Series', series),
    ];
  }

  Widget _liveShelf(String title, List<PlaylistChannel> channels) => _Shelf(
        key: ValueKey(title),
        title: title,
        height: 92,
        count: channels.length,
        builder: (context, i) => _LiveCard(
          channel: channels[i],
          onTap: () =>
              openChannel(context, ref, channels[i], playlist: channels),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final keepWatching = ref.watch(keepWatchingProvider).value ?? const [];
    final recent =
        ref.watch(recentChannelsProvider).value ?? const <PlaylistChannel>[];
    final live =
        ref.watch(recommendedChannelsProvider).value ?? const <PlaylistChannel>[];
    final curated = ref.watch(curatedShelvesProvider).value ?? const [];
    bool curatedHas<T>() => curated.any((s) => s.items.first is T);
    // The plain rankings only stand in where TMDB has nothing to offer.
    final movies = curatedHas<VodItem>()
        ? const <VodItem>[]
        : ref.watch(topMoviesProvider).value ?? const <VodItem>[];
    final series = curatedHas<SeriesItem>()
        ? const <SeriesItem>[]
        : ref.watch(topSeriesProvider).value ?? const <SeriesItem>[];

    if (live.isEmpty && movies.isEmpty && series.isEmpty && curated.isEmpty) {
      return const EmptyMessage(
          'Nothing to recommend yet. Add a source in Sources.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
      children: [
        Row(
          children: [
            Expanded(child: Text('Home', style: heading(28))),
            const SizedBox(width: 16),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: SearchField(
                  hint: 'Search everything',
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
            ),
          ],
        ),
        if (_search.isNotEmpty)
          ..._results()
        else ...[
          if (keepWatching.isNotEmpty)
            _Shelf(
              key: const ValueKey('Keep watching'),
              title: 'Keep watching',
              height: 310,
              count: keepWatching.length,
              builder: (context, i) {
                final p = keepWatching[i];
                return SizedBox(
                  width: 170,
                  child: PosterCard(
                    title: p.title,
                    url: p.posterUrl,
                    year: null,
                    rating: null,
                    progress: p.positionMs / p.durationMs,
                    onRemove: () =>
                        ref.read(databaseProvider).clearProgress(p.itemId),
                    onTap: () => openVod(
                      context,
                      ref,
                      VodItem(
                        id: p.itemId,
                        sourceId: p.sourceId,
                        title: p.title,
                        posterUrl: p.posterUrl,
                        streamUrl: p.streamUrl,
                        categoryId: '',
                        sortOrder: 0,
                      ),
                    ),
                  ),
                );
              },
            ),
          if (recent.isNotEmpty) _liveShelf('Recently watched', recent),
          if (live.isNotEmpty) _liveShelf('Live now', live),
          for (final shelf in curated) _titles(shelf.name, shelf.items),
          if (movies.isNotEmpty) _titles('Top movies', movies),
          if (series.isNotEmpty) _titles('Top series', series),
        ],
      ],
    );
  }
}

/// A titled row that scrolls sideways.
class _Shelf extends StatelessWidget {
  const _Shelf({
    super.key,
    required this.title,
    required this.height,
    required this.count,
    required this.builder,
  });

  final String title;
  final double height;
  final int count;
  final IndexedWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: heading(20)),
          const SizedBox(height: 14),
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: count,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: builder,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveCard extends ConsumerWidget {
  const _LiveCard({required this.channel, required this.onTap});

  final PlaylistChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final program = ref.watch(scheduleProvider(channel.epgKey)).value?.now;
    return SizedBox(
      width: 300,
      child: Material(
        color: OnAir.panel,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: OnAir.line),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ChannelLogo(name: channel.name, url: channel.logoUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(channel.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (program != null) ...[
                        const SizedBox(height: 4),
                        Text(program.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, color: OnAir.muted)),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progressOf(program, DateTime.now()),
                            minHeight: 3,
                            backgroundColor: OnAir.line,
                          ),
                        ),
                      ],
                    ],
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
