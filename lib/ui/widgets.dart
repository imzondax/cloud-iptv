import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/database.dart';
import 'theme.dart';

/// Up to two initials, for channels without a logo.
String monogram(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return '?';
  return words.take(2).map((w) => String.fromCharCode(w.runes.first))
      .join().toUpperCase();
}

Color tileColor(String seed) =>
    OnAir.tiles[seed.codeUnits.fold(0, (a, b) => a + b) % OnAir.tiles.length];

String clock(DateTime t) {
  final local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

String timeLeft(DateTime stop, DateTime now) {
  final minutes = stop.difference(now).inMinutes;
  if (minutes < 60) return '$minutes min left';
  return '${minutes ~/ 60} h ${minutes % 60} min left';
}

String syncedAgo(DateTime? time, DateTime now) {
  if (time == null) return 'Not synced yet';
  final age = now.difference(time);
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
  if (age.inMinutes < 1) return 'Synced just now';
  if (age.inHours < 1) return 'Synced ${plural(age.inMinutes, 'minute')}';
  if (age.inDays < 1) return 'Synced ${plural(age.inHours, 'hour')}';
  return 'Synced ${plural(age.inDays, 'day')}';
}

/// 0 to 1 through [p] at [now].
double progressOf(EpgProgram p, DateTime now) {
  final total = p.stopTime.difference(p.startTime).inSeconds;
  if (total <= 0) return 0;
  return (now.difference(p.startTime).inSeconds / total).clamp(0.0, 1.0);
}

/// The chosen category, unless it has since been hidden, locked or removed.
String? pickCategory(String? picked, List<Category> categories) =>
    picked == favoritesCategoryId || categories.any((c) => c.id == picked)
        ? picked
        : categories.firstOrNull?.id;

class ChannelLogo extends StatelessWidget {
  const ChannelLogo({
    super.key,
    required this.name,
    required this.url,
    this.size = 52,
    this.radius = 10,
  });

  final String name;
  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: tileColor(name),
      child: Center(
        child: Text(
          monogram(name),
          style: heading(size * 0.33).copyWith(color: OnAir.ground),
        ),
      ),
    );
    final src = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: src == null
            ? fallback
            : ColoredBox(
                color: OnAir.raised,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.network(
                    src,
                    // Decoding at list size keeps long lists out of trouble.
                    cacheWidth: 128,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => fallback,
                  ),
                ),
              ),
      ),
    );
  }
}

/// A poster, or a coloured card carrying the title when there is none.
class Poster extends StatelessWidget {
  const Poster({
    super.key,
    required this.title,
    required this.url,
    this.rating,
    this.selected = false,
    this.showTitle = true,
  });

  final String title;
  final String? url;
  final double? rating;
  final bool selected;

  /// Off where the poster is too small for the title and it sits alongside.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final src = url;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: selected ? Border.all(color: OnAir.accent, width: 3) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: tileColor(title),
              child: !showTitle
                  ? null
                  : Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          title,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: heading(22).copyWith(color: OnAir.ground),
                        ),
                      ),
                    ),
            ),
            if (src != null)
              Image.network(
                src,
                cacheWidth: 400,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (rating case final r? when r > 0)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: _Pill(
                    icon: Icons.star_rounded,
                    label: r.toStringAsFixed(1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: OnAir.ground,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: OnAir.accent),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: OnAir.accent)),
        ],
      ),
    );
  }
}

class LivePill extends StatelessWidget {
  const LivePill({super.key});

  @override
  Widget build(BuildContext context) {
    return const _Pill(icon: Icons.circle, label: 'LIVE');
  }
}

class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: TextField(
        onChanged: (v) => onChanged(v.trim()),
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: 20, color: OnAir.muted),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

/// One scrolling line of chips: providers can have hundreds of categories.
class CategoryChips extends ConsumerWidget {
  const CategoryChips({
    super.key,
    required this.kind,
    required this.value,
    required this.onChanged,
    this.includeFavorites = false,
  });

  final CategoryKind kind;
  final String? value;
  final ValueChanged<String> onChanged;
  final bool includeFavorites;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider(kind)).value ?? const [];
    final chips = [
      if (includeFavorites) (id: favoritesCategoryId, name: 'Favorites'),
      for (final c in categories) (id: c.id, name: c.name),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chip = chips[i];
          final selected = chip.id == value;
          return Semantics(
            selected: selected,
            button: true,
            child: Material(
              color: selected ? OnAir.accent : Colors.transparent,
              shape: StadiumBorder(
                side: BorderSide(
                    color: selected ? OnAir.accent : OnAir.line),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => onChanged(chip.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      chip.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: selected ? OnAir.accentInk : OnAir.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class EmptyMessage extends StatelessWidget {
  const EmptyMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: OnAir.muted)),
      ),
    );
  }
}
