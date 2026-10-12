import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../playlist/playlist_controller.dart';
import 'channel_filter.dart';

/// "Which groups do you want?" - shown once after the first playlist load and
/// from Settings. Unticked groups are hidden.
class GroupSetupPage extends ConsumerStatefulWidget {
  const GroupSetupPage({super.key, this.firstRun = false});
  final bool firstRun;

  @override
  ConsumerState<GroupSetupPage> createState() => _GroupSetupPageState();
}

class _GroupSetupPageState extends ConsumerState<GroupSetupPage> {
  late final List<String> _groups = ref.read(allGroupsProvider);
  late final Map<String, int> _counts = () {
    final counts = <String, int>{};
    for (final c in ref.read(playlistProvider).channels) {
      counts[c.group] = (counts[c.group] ?? 0) + 1;
    }
    return counts;
  }();
  late final Set<String> _keep = () {
    final hidden = ref.read(settingsProvider).hiddenGroups;
    // First run: start empty so you only tick what you want.
    if (widget.firstRun) return <String>{};
    return _groups.where((g) => !hidden.contains(g)).toSet();
  }();
  String _filter = '';

  void _selectWhere(bool Function(String g) test) =>
      setState(() => _keep.addAll(_groups.where(test)));

  void _save({bool keepAll = false}) {
    final keep = keepAll ? _groups.toSet() : _keep;
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(
          hiddenGroups: _groups.where((g) => !keep.contains(g)).toSet(),
          groupsConfigured: true,
        ));
    ref.read(channelFilterProvider.notifier).setGroup(null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.toLowerCase();
    final shown = _groups.where((g) => groupLabel(g).toLowerCase().contains(q)).toList();
    final channelCount = _keep.fold<int>(0, (sum, g) => sum + (_counts[g] ?? 0));

    return PopScope(
      // First run: closing the page counts as "keep everything".
      canPop: !widget.firstRun,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.firstRun) _save(keepAll: true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.firstRun ? 'Choose your groups' : 'Groups'),
          actions: [
            TextButton(
              onPressed: _keep.isEmpty ? null : _save,
              child: Text('Save (${_keep.length})'),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.firstRun)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Your playlist has many groups. Tick the ones you watch - the rest are hidden. '
                  'You can change this later in Settings.',
                  style: TextStyle(color: AppColors.textDim),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Filter groups (e.g. sports, bein, usa)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filter = v.trim()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(
                    label: const Text('+ Sports'),
                    onPressed: () => _selectWhere((g) => g.toLowerCase().contains('sport')),
                  ),
                  if (q.isNotEmpty)
                    ActionChip(
                      label: Text('+ All "$_filter"'),
                      onPressed: () => _selectWhere((g) => groupLabel(g).toLowerCase().contains(q)),
                    ),
                  ActionChip(label: const Text('Select all'), onPressed: () => _selectWhere((_) => true)),
                  ActionChip(label: const Text('Select none'), onPressed: () => setState(_keep.clear)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('${_keep.length} groups, $channelCount channels kept',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemExtent: 48,
                itemBuilder: (context, i) {
                  final g = shown[i];
                  return CheckboxListTile(
                    dense: true,
                    title: Text(groupLabel(g), maxLines: 1, overflow: TextOverflow.ellipsis),
                    secondary: Text('${_counts[g] ?? 0}', style: const TextStyle(color: AppColors.textDim)),
                    value: _keep.contains(g),
                    onChanged: (v) => setState(() => v == true ? _keep.add(g) : _keep.remove(g)),
                  );
                },
              ),
            ),
            if (widget.firstRun)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    TextButton(onPressed: () => _save(keepAll: true), child: const Text('Skip - keep all')),
                    const Spacer(),
                    FilledButton(onPressed: _keep.isEmpty ? null : _save, child: const Text('Save')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
