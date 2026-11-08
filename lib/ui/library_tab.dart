import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/database.dart';
import '../services/playlist_backend.dart';
import '../services/tmdb.dart' show titleKey;
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showEpisodes(BuildContext context, SeriesItem series) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.8,
        child: _EpisodePanel(series: series),
      ),
    );

/// Movies and Series: a poster grid. Series adds an episode panel.
class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key, required this.kind});

  final CategoryKind kind;

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab> {
  String? _picked;
  String _search = '';
  SeriesItem? _series;
  bool _panelClosed = false;
  LibraryFilters _filters = const LibraryFilters();

  bool get _isSeries => widget.kind == CategoryKind.series;
  String get _savedCategory => 'category_${widget.kind.name}';

  @override
  void initState() {
    super.initState();
    ref.read(databaseProvider).setting(_savedCategory).then((id) {
      if (mounted && id != null) setState(() => _picked ??= id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final title = _isSeries ? 'Series' : 'Movies';
    final categories = ref.watch(categoriesProvider(kind)).value ?? const [];
    final categoryId = pickCategory(_picked, categories);
    final rows = ref.watch(browseProvider(
        (kind: kind, categoryId: categoryId, search: _search)));
    final favorites = ref.watch(favoriteTitlesProvider(kind)).value ?? const {};
    // Starts the TMDB lookups, without a rebuild for each step.
    ref.listen(detailsLookupProvider, (_, _) {});
    final details = ref.watch(titleDetailsProvider).value ?? const {};
    final categoryNames = {for (final c in categories) c.id: c.name};
    final all = rows.value ?? const [];
    final shown = _filters.isEmpty
        ? all
        : all
            .where((r) =>
                _filters.matches(factsOf(r, categoryNames, details)))
            .toList();
    void toggle(String id) => ref
        .read(databaseProvider)
        .setFavoriteTitle(id, kind, !favorites.contains(id));

    return LayoutBuilder(builder: (context, constraints) {
      final panel = _isSeries && constraints.maxWidth >= 1100;
      // Locking a category must also close the series open from it.
      final picked = categories.any((c) => c.id == _series?.categoryId)
          ? _series
          : null;
      final series = picked ??
          (panel && !_panelClosed
              ? shown.whereType<SeriesItem>().firstOrNull
              : null);

      void openSeries(SeriesItem s) {
        if (panel) {
          setState(() {
            _series = s;
            _panelClosed = false;
          });
        } else {
          showEpisodes(context, s);
        }
      }

      final grid = Padding(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: heading(28))),
                const SizedBox(width: 16),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: SearchField(
                      hint: 'Search ${title.toLowerCase()}',
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDialog<LibraryFilters>(
                      context: context,
                      builder: (_) => _FiltersDialog(
                          rows: all, names: categoryNames, current: _filters),
                    );
                    if (picked != null) setState(() => _filters = picked);
                  },
                  icon: const Icon(Icons.tune, size: 18),
                  label:
                      Text(_filters.isEmpty ? 'More filters' : 'Filters on'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            CategoryChips(
              kind: kind,
              value: categoryId,
              includeFavorites: true,
              onChanged: (id) {
                setState(() => _picked = id);
                ref.read(databaseProvider).saveSetting(_savedCategory, id);
              },
            ),
            const SizedBox(height: 20),
            Expanded(
              child: switch (rows) {
                AsyncData(:final value) when value.isNotEmpty && shown.isEmpty =>
                  const EmptyMessage('No titles match these filters.'),
                AsyncData(:final value) when value.isEmpty => EmptyMessage(
                    categoryId == favoritesCategoryId
                        ? 'No favorites yet. Use the star on a poster.'
                        : 'Nothing here yet. Add a source in Sources.'),
                AsyncData() => GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 22,
                      crossAxisSpacing: 20,
                      childAspectRatio: 0.58,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => switch (shown[i]) {
                      VodItem v => PosterCard(
                          title: v.title,
                          url: v.posterUrl,
                          year: v.year,
                          rating: v.rating,
                          tv: false,
                          favorite: favorites.contains(v.id),
                          onFavorite: () => toggle(v.id),
                          onTap: () => openVod(context, ref, v),
                        ),
                      SeriesItem s => PosterCard(
                          title: s.title,
                          url: s.posterUrl,
                          year: s.year,
                          rating: s.rating,
                          selected: panel && s.id == series?.id,
                          tv: true,
                          favorite: favorites.contains(s.id),
                          onFavorite: () => toggle(s.id),
                          onTap: () => openSeries(s),
                        ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                AsyncError() =>
                  const EmptyMessage('Could not read the library'),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      );

      if (!panel || _panelClosed) return grid;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: grid),
          SizedBox(
            width: 440,
            child: series == null
                ? const ColoredBox(color: OnAir.panel)
                : _EpisodePanel(
                    key: ValueKey(series.id),
                    series: series,
                    onClose: () => setState(() {
                      _series = null;
                      _panelClosed = true;
                    }),
                  ),
          ),
        ],
      );
    });
  }
}

/// A two or three letter tag leading a title or category name, such as
/// `EN - Heat`, `[DE] Krimi` or `|FR| Action`. No colon: `CSI: Miami`.
final _languageTag = RegExp(r'^\s*[\[(|]?\s*([A-Z]{2,3})\s*[\])|-]');
const _notLanguages = {
  'HD', 'SD', 'FHD', 'UHD', 'HDR', 'VIP', 'NEW', 'TOP', 'ALL', 'VOD', 'TV',
};

/// The fallback for titles TMDB has not answered for. Guesses from tags, so
/// `IT - Chapter Two` reads as Italian.
String? languageOf(String title, String? category) {
  for (final text in [title, category ?? '']) {
    final code = _languageTag.firstMatch(text)?[1];
    if (code != null && !_notLanguages.contains(code)) return code;
  }
  return null;
}

/// The names in a panel list such as `Drama, Crime` or `Action / Comedy`.
Iterable<String> namesIn(String? list) => (list ?? '')
    .split(RegExp(r'[,/|]'))
    .map((n) => n.trim())
    .where((n) => n.isNotEmpty);

/// Names for the original languages TMDB reports most. Others show as codes.
const _languageNames = {
  'en': 'English', 'no': 'Norwegian', 'nb': 'Norwegian', 'sv': 'Swedish',
  'da': 'Danish', 'fi': 'Finnish', 'de': 'German', 'fr': 'French',
  'es': 'Spanish', 'it': 'Italian', 'pt': 'Portuguese', 'nl': 'Dutch',
  'pl': 'Polish', 'ru': 'Russian', 'tr': 'Turkish', 'ar': 'Arabic',
  'hi': 'Hindi', 'ta': 'Tamil', 'te': 'Telugu', 'ja': 'Japanese',
  'ko': 'Korean', 'zh': 'Chinese', 'cn': 'Cantonese', 'th': 'Thai',
  'is': 'Icelandic', 'el': 'Greek', 'he': 'Hebrew', 'fa': 'Persian',
};

String languageName(String code) => _languageNames[code] ?? code.toUpperCase();

/// The dropdown filters, each matching any of a title's values.
const _facets = ['Language', 'Genre', 'Director', 'Studio'];

typedef TitleFacts = ({
  Map<String, Iterable<String>> tags,
  int? year,
  double rating,
  int? age,
});

/// What the filters can see of a row: its own fields, then TMDB's details.
TitleFacts factsOf(Object row, Map<String, String> categoryNames,
    Map<String, TitleDetail> details) {
  final (title, categoryId, year, rating, tv) = switch (row) {
    VodItem v => (v.title, v.categoryId, v.year, v.rating, false),
    SeriesItem s => (s.title, s.categoryId, s.year, s.rating, true),
    _ => ('', '', null, null, false),
  };
  final detail = details[titleKey(tv: tv, title: title, year: year)];
  final series = row is SeriesItem ? row : null;
  final language = detail?.language ??
      languageOf(title, categoryNames[categoryId])?.toLowerCase();
  return (
    tags: {
      'Language': [?language],
      'Genre': namesIn(series?.genre),
      'Director': namesIn(series?.director),
      'Studio': namesIn(detail?.studios),
    },
    year: year,
    rating: rating ?? 0,
    age: detail?.ageLimit,
  );
}

class LibraryFilters {
  const LibraryFilters({
    this.picks = const {},
    this.years,
    this.minRating = 0,
    this.maxAge,
  });

  /// A chosen value per facet, such as `{'Language': 'en'}`.
  final Map<String, String> picks;
  final RangeValues? years;
  final double minRating;

  /// Titles rated for this age or younger. Unrated titles drop out.
  final int? maxAge;

  bool get isEmpty =>
      picks.isEmpty && years == null && minRating == 0 && maxAge == null;

  bool matches(TitleFacts t) {
    final (year, years, age, maxAge) = (t.year, this.years, t.age, this.maxAge);
    return picks.entries.every((p) => t.tags[p.key]!.contains(p.value)) &&
        (years == null ||
            (year != null && year >= years.start && year <= years.end)) &&
        t.rating >= minRating &&
        (maxAge == null || (age != null && age <= maxAge));
  }
}

/// Offers only the values the rows contain, and fills in as TMDB answers.
class _FiltersDialog extends ConsumerStatefulWidget {
  const _FiltersDialog({
    required this.rows,
    required this.names,
    required this.current,
  });

  final List<Object> rows;
  final Map<String, String> names;
  final LibraryFilters current;

  @override
  ConsumerState<_FiltersDialog> createState() => _FiltersDialogState();
}

class _FiltersDialogState extends ConsumerState<_FiltersDialog> {
  late final _picks = {...widget.current.picks};
  late RangeValues? _years = widget.current.years;
  late double _minRating = widget.current.minRating;
  late int? _maxAge = widget.current.maxAge;

  Widget _pick<T extends Object>(String label, Iterable<T> options, T? value,
      String Function(T) name, void Function(T?) onSelected) {
    if (options.isEmpty) return const SizedBox.shrink();
    final many = options.length > 12;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownMenu<T?>(
        label: Text(label),
        expandedInsets: EdgeInsets.zero,
        menuHeight: 320,
        initialSelection: options.contains(value) ? value : null,
        enableFilter: many,
        requestFocusOnTap: many,
        dropdownMenuEntries: [
          DropdownMenuEntry(value: null, label: 'Any'),
          for (final o in options) DropdownMenuEntry(value: o, label: name(o)),
        ],
        onSelected: (v) => setState(() => onSelected(v)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(titleDetailsProvider).value ?? const {};
    final values = {for (final f in _facets) f: <String>{}};
    final years = <int>{};
    final ages = <int>{};
    for (final row in widget.rows) {
      final t = factsOf(row, widget.names, details);
      for (final f in _facets) {
        values[f]!.addAll(t.tags[f]!);
      }
      if (t.year case final y?) years.add(y);
      if (t.age case final a?) ages.add(a);
    }
    final first = (years.isEmpty ? 0 : years.reduce(min)).toDouble();
    final last = (years.isEmpty ? 0 : years.reduce(max)).toDouble();
    final range = _years ?? RangeValues(first, last);

    final hasKey = (ref.watch(tmdbKeyProvider).value ?? '').isNotEmpty;
    final lookup = ref.watch(detailsLookupProvider);
    final status = switch (lookup) {
      _ when !hasKey => 'Add a TMDB key in Sources to filter by language, '
          'studio and age limit.',
      AsyncError(:final error) => 'TMDB lookups stopped: ${safeError(error)}',
      AsyncData(value: (:final done, :final total)) when done < total =>
        'Looking up language, studio and age limit on TMDB: '
            '$done of $total. Choices fill in as it goes.',
      _ => null,
    };

    String Function(String) nameFor(String facet) =>
        facet == 'Language' ? languageName : (s) => s;

    return AlertDialog(
      title: Text('More filters', style: heading(22)),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (status != null) ...[
                Text(status,
                    style: const TextStyle(fontSize: 13, color: OnAir.muted)),
                const SizedBox(height: 14),
              ],
              const SizedBox(height: 6),
              for (final facet in _facets)
                _pick<String>(
                  facet,
                  values[facet]!.toList()
                    ..sort((a, b) =>
                        nameFor(facet)(a).compareTo(nameFor(facet)(b))),
                  _picks[facet],
                  nameFor(facet),
                  (v) => v == null ? _picks.remove(facet) : _picks[facet] = v,
                ),
              _pick<int>(
                'Age limit',
                ages.toList()..sort(),
                _maxAge,
                (a) => a == 0 ? 'All ages' : 'Up to $a',
                (v) => _maxAge = v,
              ),
              if (first < last) ...[
                Text('Released ${range.start.round()} to ${range.end.round()}'),
                RangeSlider(
                  min: first,
                  max: last,
                  divisions: (last - first).round(),
                  values: RangeValues(range.start.clamp(first, last),
                      range.end.clamp(first, last)),
                  labels: RangeLabels(
                      '${range.start.round()}', '${range.end.round()}'),
                  // The full span is no filter, so undated titles stay.
                  onChanged: (r) => setState(() => _years =
                      r.start <= first && r.end >= last ? null : r),
                ),
              ],
              Text(_minRating == 0
                  ? 'Any rating'
                  : 'Rated ${_minRating.toStringAsFixed(1)} or more'),
              Slider(
                max: 10,
                divisions: 20,
                value: _minRating,
                label: _minRating.toStringAsFixed(1),
                onChanged: (v) => setState(() => _minRating = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const LibraryFilters()),
          child: const Text('Clear'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LibraryFilters(
              picks: _picks,
              years: _years,
              minRating: _minRating,
              maxAge: _maxAge,
            ),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class PosterCard extends ConsumerWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.url,
    required this.year,
    required this.rating,
    required this.onTap,
    this.selected = false,
    this.progress,
    this.tv,
    this.favorite = false,
    this.onFavorite,
    this.onRemove,
  });

  final String title;
  final String? url;
  final int? year;
  final double? rating;
  final VoidCallback onTap;
  final bool selected;

  /// 0 to 1, for something partly watched.
  final double? progress;

  /// Whether this is a series or a movie, for finding missing artwork. Null
  /// when the title alone would not find it, as with an episode.
  final bool? tv;

  final bool favorite;
  final VoidCallback? onFavorite;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = tv;
    final art = url ??
        (kind == null
            ? null
            : ref
                .watch(fallbackPosterProvider(
                    (title: title, year: year, tv: kind)))
                .value);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Poster(
                  title: title,
                  url: art,
                  rating: rating,
                  selected: selected,
                ),
                if (onFavorite case final toggle?)
                  _PosterButton(
                    tooltip:
                        favorite ? 'Remove from favorites' : 'Add to favorites',
                    icon: favorite
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    onPressed: toggle,
                  ),
                if (onRemove case final remove?)
                  _PosterButton(
                    tooltip: 'Remove from Keep watching',
                    icon: Icons.close,
                    onPressed: remove,
                  ),
              ],
            ),
          ),
          if (progress case final value?) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 3,
                backgroundColor: OnAir.line,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              if (year != null) ...[
                const SizedBox(width: 8),
                Text('$year', style: const TextStyle(color: OnAir.muted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PosterButton extends StatelessWidget {
  const _PosterButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          style: IconButton.styleFrom(backgroundColor: OnAir.ground),
          icon: Icon(icon, size: 20, color: OnAir.accent),
        ),
      ),
    );
  }
}

class _EpisodePanel extends ConsumerStatefulWidget {
  const _EpisodePanel({super.key, required this.series, this.onClose});

  final SeriesItem series;

  /// Shown as an X in the side panel. A bottom sheet closes on its own.
  final VoidCallback? onClose;

  @override
  ConsumerState<_EpisodePanel> createState() => _EpisodePanelState();
}

class _EpisodePanelState extends ConsumerState<_EpisodePanel> {
  int? _season;

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    final episodes = ref.watch(episodesProvider(series));
    final details = [
      if (series.year != null) '${series.year}',
      if (series.rating case final r? when r > 0)
        'Rated ${r.toStringAsFixed(1)}',
    ].join(' · ');

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: OnAir.panel,
        border: Border(left: BorderSide(color: OnAir.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 92,
                  height: 138,
                  child: Poster(
                    title: series.title,
                    url: series.posterUrl,
                    showTitle: false,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(series.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: heading(24)),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(details,
                            style: const TextStyle(
                                fontSize: 13, color: OnAir.muted)),
                      ],
                    ],
                  ),
                ),
                if (widget.onClose case final close?)
                  // As tall as the poster, so the X sits at its top.
                  Container(
                    height: 138,
                    alignment: Alignment.topRight,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: close,
                      icon: const Icon(Icons.close),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: switch (episodes) {
                AsyncData(:final value) when value.isEmpty =>
                  const EmptyMessage('No episodes found'),
                AsyncData(:final value) => _episodeList(value),
                AsyncError(:final error) => EmptyMessage(safeError(error)),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeList(List<Episode> episodes) {
    final seasons = episodes.map((e) => e.season).toSet().toList()..sort();
    final season = _season ?? seasons.first;
    final shown = episodes.where((e) => e.season == season).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: seasons.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final selected = seasons[i] == season;
              return Semantics(
                selected: selected,
                button: true,
                child: Material(
                  color: selected ? OnAir.accentSoft : OnAir.raised,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _season = seasons[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          'Season ${seasons[i]}',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: selected ? OnAir.accent : OnAir.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemExtent: 61,
            itemBuilder: (context, i) {
              final e = shown[i];
              return Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: OnAir.line)),
                ),
                // Its own Material: ink would hide behind the opaque panel.
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => _play(e, episodes),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text('${e.number}',
                              style: heading(17).copyWith(color: OnAir.muted)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(e.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w500)),
                              if (e.duration case final d?) ...[
                                const SizedBox(height: 3),
                                Text(d,
                                    style: const TextStyle(
                                        fontSize: 12, color: OnAir.muted)),
                              ],
                            ],
                          ),
                        ),
                        const Icon(Icons.play_arrow_rounded,
                            color: OnAir.accent),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _play(Episode episode, List<Episode> episodes) {
    final ordered = [...episodes]..sort((a, b) => a.season != b.season
        ? a.season.compareTo(b.season)
        : a.number.compareTo(b.number));
    final upNext = ordered
        .skip(ordered.indexOf(episode) + 1)
        .map((e) => e.item)
        .toList();
    // Inside a bottom sheet, close it first so the player opens on top.
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route is ModalBottomSheetRoute) navigator.pop();
    openVod(navigator.context, ref, episode.item, upNext: upNext);
  }
}
