import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import 'library_tab.dart';
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class DashboardTab extends ConsumerWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        Text('Home', style: heading(28)),
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
        if (recent.isNotEmpty)
          _Shelf(
            key: const ValueKey('Recently watched'),
            title: 'Recently watched',
            height: 92,
            count: recent.length,
            builder: (context, i) => _LiveCard(
              channel: recent[i],
              onTap: () =>
                  openChannel(context, ref, recent[i], playlist: recent),
            ),
          ),
        if (live.isNotEmpty)
          _Shelf(
            key: const ValueKey('Live now'),
            title: 'Live now',
            height: 92,
            count: live.length,
            builder: (context, i) => _LiveCard(
              channel: live[i],
              onTap: () => openChannel(context, ref, live[i], playlist: live),
            ),
          ),
        for (final shelf in curated)
          _Shelf(
            key: ValueKey(shelf.name),
            title: shelf.name,
            height: 300,
            count: shelf.items.length,
            builder: (context, i) => SizedBox(
              width: 170,
              child: switch (shelf.items[i]) {
                VodItem m => PosterCard(
                    title: m.title,
                    url: m.posterUrl,
                    year: m.year,
                    rating: m.rating,
                    onTap: () => openVod(context, ref, m),
                  ),
                SeriesItem s => PosterCard(
                    title: s.title,
                    url: s.posterUrl,
                    year: s.year,
                    rating: s.rating,
                    onTap: () => showEpisodes(context, s),
                  ),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        if (movies.isNotEmpty)
          _Shelf(
            key: const ValueKey('Top movies'),
            title: 'Top movies',
            height: 300,
            count: movies.length,
            builder: (context, i) {
              final m = movies[i];
              return SizedBox(
                width: 170,
                child: PosterCard(
                  title: m.title,
                  url: m.posterUrl,
                  year: m.year,
                  rating: m.rating,
                  onTap: () => openVod(context, ref, m),
                ),
              );
            },
          ),
        if (series.isNotEmpty)
          _Shelf(
            key: const ValueKey('Top series'),
            title: 'Top series',
            height: 300,
            count: series.length,
            builder: (context, i) {
              final s = series[i];
              return SizedBox(
                width: 170,
                child: PosterCard(
                  title: s.title,
                  url: s.posterUrl,
                  year: s.year,
                  rating: s.rating,
                  onTap: () => showEpisodes(context, s),
                ),
              );
            },
          ),
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
