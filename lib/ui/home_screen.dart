import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/secrets.dart';
import '../services/updates.dart';
import 'dashboard_tab.dart';
import 'guide_tab.dart';
import 'library_tab.dart';
import 'live_tab.dart';
import 'player_screen.dart';
import 'sources_tab.dart';
import 'theme.dart';
import 'widgets.dart';

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
  static const _savedTab = 'last_tab';

  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Startup reads only the cache. The network waits for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _offerUpdate();
      try {
        // Older versions kept logins in the database.
        await moveLoginsToKeychain(
            ref.read(databaseProvider), ref.read(secretsProvider));
      } catch (_) {
        // They stay where they were, and still work; next start tries again.
      }
      if (mounted) ref.read(syncProvider.notifier).syncAll(onlyStale: true);
    });
    ref.read(databaseProvider).setting(_savedTab).then((saved) {
      final tab = int.tryParse(saved ?? '');
      if (mounted && tab != null) setState(() => _tab = tab);
    });
  }

  void _go(int tab) {
    setState(() => _tab = tab);
    ref.read(databaseProvider).saveSetting(_savedTab, '$tab');
  }

  Future<void> _offerUpdate() async {
    final version = await ref.read(updateProvider.future);
    if (version == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 15),
      content: Text('Cloud IPTV $version is available'),
      action: SnackBarAction(
        label: 'Get it',
        onPressed: () => launchUrl(Uri.parse(releasesUrl)),
      ),
    ));
  }

  Future<void> _fireReminders() async {
    final now = DateTime.now();
    final db = ref.read(databaseProvider);
    final due = await db.takeDueReminders(now.add(const Duration(minutes: 2)));
    for (final r in due) {
      // Set before the app was closed, and long gone by now.
      if (r.startTime.isBefore(now.subtract(const Duration(minutes: 10)))) {
        continue;
      }
      final channel = await db.channelById(r.channelId);
      if (channel == null || !mounted) continue;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(minutes: 1),
        content:
            Text('${r.title} starts at ${clock(r.startTime)} on ${channel.name}'),
        action: SnackBarAction(
          label: 'Watch',
          onPressed: () {
            if (ref.read(activeStreamProvider) == null) {
              openChannel(context, ref, channel, playlist: [channel]);
            } else {
              ref.read(activeStreamProvider.notifier).playChannel(channel);
            }
          },
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(minuteProvider, (_, _) => _fireReminders());
    ref.listen(syncProvider, (_, next) {
      if (next.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });
    final syncing = ref.watch(syncProvider.select((s) => s.running));
    final step = ref.watch(syncProvider.select((s) => s.step));

    final content = Column(
      children: [
        SizedBox(
          height: 2,
          child: syncing ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        if (syncing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'Syncing ${step ?? 'sources'}…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: OnAir.muted),
            ),
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
            onSelected: _go,
            home: _tab == _dashboard,
            onHome: () => _go(_dashboard),
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
