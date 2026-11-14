import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../player/iptv_player.dart';
import '../providers/providers.dart';
import '../services/database.dart';
import '../services/playlist_backend.dart';
import 'theme.dart';
import 'widgets.dart';

class SourcesTab extends ConsumerWidget {
  const SourcesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).value ?? const <Source>[];
    final syncing = ref.watch(syncProvider.select((s) => s.running));
    final hardware = ref.watch(hardwareAccelerationProvider).value ?? true;
    final buffer =
        ref.watch(bufferProfileProvider).value ?? BufferProfile.medium;
    // A new or re-added source has no locks, so this needs the PIN as well.
    final guarded = ref.watch(settingProvider(pinKey)).value != null &&
        !(ref.watch(unlockedProvider).value ?? false);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 944),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                Text('Sources', style: heading(28)),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.sync, size: 18),
                      label: Text(syncing ? 'Syncing…' : 'Sync now'),
                      onPressed: syncing
                          ? null
                          : () => ref.read(syncProvider.notifier).syncAll(),
                    ),
                    if (!guarded)
                      FilledButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add source'),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => const _SourceDialog(),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (sources.isEmpty)
              const _Card(
                child: Text(
                  'No sources yet. Add an M3U playlist or Xtream Codes login to '
                  'start watching.',
                  style: TextStyle(color: OnAir.muted),
                ),
              ),
            for (final s in sources) ...[
              _SourceCard(source: s, editable: !guarded),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 16),
            Text('Recommendations', style: heading(20)),
            const SizedBox(height: 10),
            const _TmdbCard(),
            const SizedBox(height: 28),
            Text('Categories', style: heading(20)),
            const SizedBox(height: 10),
            const _ParentalCard(),
            const SizedBox(height: 28),
            Text('Playback', style: heading(20)),
            const SizedBox(height: 10),
            _Card(
              child: MergeSemantics(
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Hardware acceleration',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          SizedBox(height: 3),
                          Text(
                            'Turn off if video shows artifacts or a black '
                            'picture.',
                            style:
                                TextStyle(fontSize: 13, color: OnAir.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Switch(
                      value: hardware,
                      onChanged:
                          ref.read(hardwareAccelerationProvider.notifier).set,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Buffer',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  const Text(
                    'Small changes channels fastest. Large rides out a shaky '
                    'connection.',
                    style: TextStyle(fontSize: 13, color: OnAir.muted),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<BufferProfile>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: BufferProfile.small, label: Text('Small')),
                      ButtonSegment(
                          value: BufferProfile.medium, label: Text('Medium')),
                      ButtonSegment(
                          value: BufferProfile.large, label: Text('Large')),
                    ],
                    selected: {buffer},
                    onSelectionChanged: (s) => ref
                        .read(bufferProfileProvider.notifier)
                        .set(s.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _LanguageCard(),
          ],
        ),
      ),
    );
  }
}

const _languages = {
  '': 'Automatic',
  'en,eng': 'English',
  'no,nor,nob,nb': 'Norwegian',
  'sv,swe': 'Swedish',
  'da,dan': 'Danish',
  'fi,fin': 'Finnish',
  'de,deu,ger': 'German',
  'fr,fra,fre': 'French',
  'es,spa': 'Spanish',
  'it,ita': 'Italian',
  'nl,nld,dut': 'Dutch',
  'pt,por': 'Portuguese',
  'pl,pol': 'Polish',
  'tr,tur': 'Turkish',
  'ar,ara': 'Arabic',
};

class _LanguageCard extends ConsumerWidget {
  const _LanguageCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget picker(String label, String key) {
      final saved = ref.watch(settingProvider(key)).value ?? '';
      return Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<String>(
            value: _languages.containsKey(saved) ? saved : '',
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _languages.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) =>
                ref.read(databaseProvider).saveSetting(key, v ?? ''),
          ),
        ],
      );
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Preferred languages',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          const Text(
            'Picked whenever a stream offers them. Applies from the next '
            'stream you open.',
            style: TextStyle(fontSize: 13, color: OnAir.muted),
          ),
          const SizedBox(height: 8),
          picker('Audio', audioLanguageKey),
          picker('Subtitles', subtitleLanguageKey),
        ],
      ),
    );
  }
}

/// Hiding and locking sit behind the PIN, or a child could just undo them.
class _ParentalCard extends ConsumerWidget {
  const _ParentalCard();

  Future<String?> _askPin(BuildContext context, String title) {
    final pin = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: heading(22)),
        content: TextField(
          controller: pin,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'At least 4 digits'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, pin.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _setPin(BuildContext context, WidgetRef ref) async {
    final pin = await _askPin(context, 'Choose a PIN');
    if (pin == null) return;
    if (!RegExp(r'^\d{4,}$').hasMatch(pin)) {
      if (context.mounted) _tell(context, 'A PIN needs at least 4 digits');
      return;
    }
    final db = ref.read(databaseProvider);
    await db.saveSetting(pinKey, hashPin(pin));
    await db.setUnlocked(true);
  }

  Future<void> _unlock(
      BuildContext context, WidgetRef ref, String saved) async {
    final pin = await _askPin(context, 'Enter your PIN');
    if (pin == null) return;
    if (hashPin(pin) == saved) {
      await ref.read(databaseProvider).setUnlocked(true);
    } else if (context.mounted) {
      _tell(context, 'Wrong PIN');
    }
  }

  Future<void> _removePin(WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    await db.clearLocks();
    await db.deleteSetting(pinKey);
    await db.setUnlocked(false);
  }

  void _tell(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(settingProvider(pinKey)).value;
    final unlocked = ref.watch(unlockedProvider).value ?? false;
    final open = saved == null || unlocked;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hide and lock categories',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(
            saved == null
                ? 'Hide groups you never want to see. Set a PIN to lock groups '
                    'as well.'
                : unlocked
                    ? 'Unlocked until you lock it again or close the app.'
                    : 'Locked categories are out of sight until you enter your '
                        'PIN.',
            style: const TextStyle(fontSize: 13, color: OnAir.muted),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (open)
                OutlinedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _CategoriesDialog(canLock: saved != null),
                  ),
                  child: const Text('Manage categories'),
                ),
              if (saved == null)
                OutlinedButton(
                  onPressed: () => _setPin(context, ref),
                  child: const Text('Set PIN'),
                )
              else if (unlocked) ...[
                OutlinedButton(
                  onPressed: () =>
                      ref.read(databaseProvider).setUnlocked(false),
                  child: const Text('Lock now'),
                ),
                OutlinedButton(
                  onPressed: () => _removePin(ref),
                  child: const Text('Remove PIN'),
                ),
              ] else
                OutlinedButton(
                  onPressed: () => _unlock(context, ref, saved),
                  child: const Text('Unlock'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoriesDialog extends ConsumerStatefulWidget {
  const _CategoriesDialog({required this.canLock});

  final bool canLock;

  @override
  ConsumerState<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends ConsumerState<_CategoriesDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final db = ref.read(databaseProvider);
    final rules = ref.watch(categoryRulesProvider).value ?? const {};
    final query = _search.toLowerCase();
    final categories = (ref.watch(allCategoriesProvider).value ?? const [])
        .where((c) => c.name.toLowerCase().contains(query))
        .toList();
    return AlertDialog(
      title: Text('Categories', style: heading(24)),
      content: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          children: [
            SearchField(
              hint: 'Search categories',
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: categories.length,
                itemExtent: 56,
                itemBuilder: (context, i) {
                  final c = categories[i];
                  final hidden = rules[c.id]?.hidden ?? false;
                  final locked = rules[c.id]?.locked ?? false;
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(c.name, overflow: TextOverflow.ellipsis),
                            Text(
                              switch (c.kind) {
                                CategoryKind.live => 'Live',
                                CategoryKind.vod => 'Movies',
                                CategoryKind.series => 'Series',
                              },
                              style: const TextStyle(
                                  fontSize: 12, color: OnAir.muted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: hidden ? 'Show ${c.name}' : 'Hide ${c.name}',
                        icon: Icon(
                          hidden
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: hidden ? OnAir.accent : OnAir.muted,
                        ),
                        onPressed: () => db.setCategoryRule(c.id,
                            hidden: !hidden, locked: locked),
                      ),
                      IconButton(
                        tooltip: !widget.canLock
                            ? 'Set a PIN to lock categories'
                            : locked
                                ? 'Unlock ${c.name}'
                                : 'Lock ${c.name}',
                        icon: Icon(
                          locked ? Icons.lock : Icons.lock_open_outlined,
                          color: locked ? OnAir.accent : OnAir.muted,
                        ),
                        onPressed: widget.canLock
                            ? () => db.setCategoryRule(c.id,
                                hidden: hidden, locked: !locked)
                            : null,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _TmdbCard extends ConsumerStatefulWidget {
  const _TmdbCard();

  @override
  ConsumerState<_TmdbCard> createState() => _TmdbCardState();
}

class _TmdbCardState extends ConsumerState<_TmdbCard> {
  final _key = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(tmdbKeyProvider);
    if (!_loaded && saved.hasValue) {
      _loaded = true;
      _key.text = saved.value ?? '';
    }
    final shelves = ref.watch(curatedShelvesProvider);
    final status = switch (shelves) {
      AsyncError(:final error) => safeError(error),
      AsyncData(:final value) when saved.value != null && value.isEmpty =>
        'None of TMDB\'s lists match your sources yet.',
      AsyncData(:final value) when value.isNotEmpty =>
        'Showing ${value.length} lists on Home.',
      _ => null,
    };
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TMDB API key',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          const Text(
            'Adds trending, top rated and Westerns lists to Home. Get a free '
            'key at themoviedb.org/settings/api.',
            style: TextStyle(fontSize: 13, color: OnAir.muted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _key,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste your key',
                    fillColor: OnAir.ground,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () => ref
                    .read(tmdbKeyProvider.notifier)
                    .set(_key.text.trim()),
                child: const Text('Save key'),
              ),
            ],
          ),
          if (status != null) ...[
            const SizedBox(height: 10),
            Text(status,
                style:
                    const TextStyle(fontSize: 13, color: OnAir.accentText)),
          ],
          const SizedBox(height: 12),
          const Text(
            'This product uses the TMDB API but is not endorsed or certified '
            'by TMDB.',
            style: TextStyle(fontSize: 12, color: OnAir.muted),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: OnAir.panel,
        border: Border.all(color: OnAir.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.source, required this.editable});

  final Source source;
  final bool editable;

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${source.name}?', style: heading(22)),
        content: const Text(
            'Its channels and favorites will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(databaseProvider).deleteSource(source.id);
      await ref.read(secretsProvider).savePassword(source.id, null);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = source;
    final xtream = s.type == BackendType.xtream;
    final stats = ref.watch(sourceStatsProvider(s.id)).value;
    final issue = ref.watch(syncProvider.select((v) => v.issues[s.id]));

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: OnAir.raised,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(xtream ? 'XC' : 'M3U',
                    style: heading(13).copyWith(color: OnAir.accent)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                      '${xtream ? 'Xtream login' : 'Playlist'} · '
                      '${syncedAgo(s.lastSyncedAt, DateTime.now())}',
                      style:
                          const TextStyle(fontSize: 13, color: OnAir.muted),
                    ),
                  ],
                ),
              ),
              if (editable) ...[
                IconButton(
                  tooltip: 'Edit ${s.name}',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _SourceDialog(source: s),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove ${s.name}',
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: OnAir.muted),
                  onPressed: () => _confirmDelete(context, ref),
                ),
              ],
            ],
          ),
          if (stats != null) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 28,
              runSpacing: 8,
              children: [
                for (final text in [
                  '${stats.live} channels',
                  '${stats.movies} movies',
                  '${stats.series} series',
                  stats.guide == 0
                      ? 'No guide'
                      : 'Guide for ${stats.guide} channels',
                ])
                  Text(text,
                      style: const TextStyle(fontSize: 13, color: OnAir.body)),
              ],
            ),
          ],
          if (issue != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: OnAir.accentSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(issue,
                  style: const TextStyle(
                      fontSize: 13, height: 1.45, color: OnAir.accentText)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Adds a source, or edits [source] when given.
class _SourceDialog extends ConsumerStatefulWidget {
  const _SourceDialog({this.source});

  final Source? source;

  @override
  ConsumerState<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends ConsumerState<_SourceDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.source?.name);
  late final _url = TextEditingController(text: widget.source?.url);
  late final _username = TextEditingController(text: widget.source?.username);
  final _password = TextEditingController();
  late final _epg = TextEditingController(text: widget.source?.epgUrl);
  late BackendType _type = widget.source?.type ?? BackendType.m3u;
  bool _showPassword = false;

  /// What the keychain held when the dialog opened.
  String? _savedPassword;

  @override
  void initState() {
    super.initState();
    if (widget.source case final source?) {
      ref.read(secretsProvider).password(source).then((password) {
        _savedPassword = password;
        // Unless the user started typing first.
        if (mounted && _password.text.isEmpty) _password.text = password ?? '';
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _username, _password, _epg]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _required(String? v) =>
      v == null || v.trim().isEmpty ? 'Required' : null;

  String? _httpUrl(String? v) {
    final uri = Uri.tryParse(v?.trim() ?? '');
    final ok = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    return ok ? null : 'Enter an http:// or https:// URL';
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final xtream = _type == BackendType.xtream;
    final name = _name.text.trim();
    final url = _url.text.trim();
    final username = xtream ? _username.text.trim() : null;
    final password = xtream ? _password.text : null;
    final epgText = _epg.text.trim();
    final epg = xtream || epgText.isEmpty ? null : epgText;

    final db = ref.read(databaseProvider);
    final secrets = ref.read(secretsProvider);
    final existing = widget.source;
    var needsSync = true;
    // Only where the keychain is unavailable does a password stay in the
    // database, until a later start can move it.
    Future<Value<String?>> keep(int id) async =>
        Value(await secrets.savePassword(id, password) ? null : password);
    if (existing == null) {
      final id = await db.addSource(SourcesCompanion.insert(
        type: _type,
        name: name,
        url: url,
        username: Value(username),
        epgUrl: Value(epg),
      ));
      if (password != null) {
        await db.updateSource(id, SourcesCompanion(password: await keep(id)));
      }
    } else {
      final newPassword = password != _savedPassword;
      needsSync = url != existing.url ||
          username != existing.username ||
          newPassword ||
          epg != existing.epgUrl;
      // An old ETag means nothing to a new server, so a connection change
      // must force a full refresh.
      await db.updateSource(
        existing.id,
        SourcesCompanion(
          name: Value(name),
          url: Value(url),
          username: Value(username),
          password:
              newPassword ? await keep(existing.id) : const Value.absent(),
          epgUrl: Value(epg),
          etag: needsSync ? const Value(null) : const Value.absent(),
          lastSyncedAt: needsSync ? const Value(null) : const Value.absent(),
        ),
      );
    }
    if (!mounted) return;
    Navigator.pop(context);
    if (needsSync) ref.read(syncProvider.notifier).syncAll(onlyStale: true);
  }

  InputDecoration _field(String label, {Widget? suffix}) => InputDecoration(
        labelText: label,
        suffixIcon: suffix,
        fillColor: OnAir.ground,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: const TextStyle(color: OnAir.text),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: OnAir.fieldLine),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: OnAir.accent),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final xtream = _type == BackendType.xtream;
    final editing = widget.source != null;
    // A running sync would mark this source fresh using its old details.
    final syncing = ref.watch(syncProvider.select((s) => s.running));
    const gap = SizedBox(height: 18);

    return AlertDialog(
      title: Text(editing ? 'Edit source' : 'Add source', style: heading(24)),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<BackendType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: BackendType.m3u, label: Text('M3U')),
                    ButtonSegment(
                        value: BackendType.xtream, label: Text('Xtream Codes')),
                  ],
                  selected: {_type},
                  // Channel ids differ per type, so changing it would lose
                  // favourites. That takes a new source instead.
                  onSelectionChanged: editing
                      ? null
                      : (s) => setState(() => _type = s.first),
                ),
                if (editing) ...[
                  const SizedBox(height: 8),
                  const Text(
                    "The type can't change, because that would remove your "
                    'favorites. Add a new source instead.',
                    style: TextStyle(fontSize: 12, color: OnAir.muted),
                  ),
                ],
                gap,
                TextFormField(
                  controller: _name,
                  decoration: _field('Name'),
                  validator: _required,
                ),
                gap,
                TextFormField(
                  controller: _url,
                  decoration:
                      _field(xtream ? 'Server URL' : 'Playlist URL'),
                  keyboardType: TextInputType.url,
                  validator: _httpUrl,
                ),
                gap,
                if (xtream) ...[
                  TextFormField(
                    controller: _username,
                    decoration: _field('Username'),
                    validator: _required,
                  ),
                  gap,
                  TextFormField(
                    controller: _password,
                    obscureText: !_showPassword,
                    validator: _required,
                    decoration: _field(
                      'Password',
                      suffix: IconButton(
                        tooltip:
                            _showPassword ? 'Hide password' : 'Show password',
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                          color: OnAir.muted,
                        ),
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                  ),
                ] else
                  TextFormField(
                    controller: _epg,
                    decoration: _field('XMLTV guide URL (optional)'),
                    keyboardType: TextInputType.url,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? null : _httpUrl(v),
                  ),
                if (editing) ...[
                  gap,
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: OnAir.raised,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Changing the URL or login resyncs this source. Your '
                      'favorites are kept.',
                      style: TextStyle(
                          fontSize: 13, height: 1.45, color: OnAir.body),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: syncing ? null : _save,
          child: Text(syncing ? 'Syncing…' : (editing ? 'Save' : 'Add')),
        ),
      ],
    );
  }
}
