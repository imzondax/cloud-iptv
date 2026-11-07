import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import 'dashboard_tab.dart';
import 'guide_tab.dart';
import 'library_tab.dart';
import 'live_tab.dart';
import 'sources_tab.dart';
import 'theme.dart';

const _destinations = [
  (label: 'Live', icon: Icons.live_tv_outlined),
  (label: 'Movies', icon: Icons.movie_outlined),
  (label: 'Series', icon: Icons.layers_outlined),
  (label: 'Guide', icon: Icons.grid_view_outlined),
  (label: 'Sources', icon: Icons.tune),
];

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Reached from the brand tile, so it sits after the rail's destinations.
  static const _dashboard = 5;

  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Startup reads only the cache. The network waits for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncProvider.notifier).syncAll(onlyStale: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(syncProvider, (_, next) {
      if (next.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });
    final syncing = ref.watch(syncProvider.select((s) => s.running));

    final content = Column(
      children: [
        SizedBox(
          height: 2,
          child: syncing ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: const [
              LiveTab(),
              LibraryTab(kind: CategoryKind.vod),
              LibraryTab(kind: CategoryKind.series),
              GuideTab(),
              SourcesTab(),
              DashboardTab(),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final narrow = constraints.maxWidth < 760;
          final rail = _Rail(
            horizontal: narrow,
            selected: _tab,
            onSelected: (i) => setState(() => _tab = i),
            home: _tab == _dashboard,
            onHome: () => setState(() => _tab = _dashboard),
          );
          return narrow
              ? Column(children: [rail, Expanded(child: content)])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [rail, Expanded(child: content)],
                );
        }),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.horizontal,
    required this.selected,
    required this.onSelected,
    required this.home,
    required this.onHome,
  });

  final bool horizontal;
  final int selected;
  final ValueChanged<int> onSelected;
  final bool home;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final (i, d) in _destinations.indexed)
        _RailItem(
          label: d.label,
          icon: d.icon,
          selected: i == selected,
          onTap: () => onSelected(i),
        ),
    ];
    const edge = BorderSide(color: OnAir.line);
    final brand = _Brand(selected: home, onTap: onHome);
    if (horizontal) {
      return DecoratedBox(
        decoration: const BoxDecoration(border: Border(bottom: edge)),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: brand,
              ),
              for (final item in items) Expanded(child: item),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(border: Border(right: edge)),
      child: SizedBox(
        width: 96,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              brand,
              const SizedBox(height: 18),
              for (final item in items) ...[
                item,
                const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Semantics(
      selected: selected,
      button: true,
      child: Tooltip(
        message: 'Home',
        child: SizedBox.square(
          dimension: 44,
          child: Material(
            color: selected ? OnAir.accentSoft : Colors.transparent,
            shape: shape,
            child: InkWell(
              customBorder: shape,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Image.asset('assets/logo.png',
                    filterQuality: FilterQuality.medium),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? OnAir.accent : OnAir.muted;
    return Semantics(
      selected: selected,
      button: true,
      child: SizedBox(
        width: 72,
        height: 64,
        child: Material(
          color: selected ? OnAir.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
