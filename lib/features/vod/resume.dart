import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../playlist/channel.dart';
import 'catalog_page.dart';

/// Started movies/episodes, most recent first. Updates live while playing.
final resumeListProvider = StreamProvider<List<PlaybackPosition>>(
  (ref) => ref.watch(databaseProvider).watchPositions(),
);

final resumeByIdProvider = Provider<Map<String, PlaybackPosition>>((ref) {
  final list = ref.watch(resumeListProvider).valueOrNull ?? const [];
  return {for (final p in list) p.mediaId: p};
});

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

extension ResumeInfo on PlaybackPosition {
  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1).toDouble();
  String get label =>
      'Continue from ${formatDuration(position)} of ${formatDuration(duration)}';

  /// The same playable item as when it was saved (same id -> same resume point).
  Channel toMedia() => Channel(
    id: mediaId,
    name: title,
    url: url,
    logo: logo,
    tvgId: ref,
    group: ref.startsWith('series:') ? 'Series' : 'Movies',
  );
}

/// Thin progress bar + "Continue from 23:41 of 1:45:00".
class ResumeProgress extends StatelessWidget {
  const ResumeProgress({super.key, required this.position});
  final PlaybackPosition position;

  @override
  Widget build(BuildContext context) {
    if (position.watched) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 16, color: Colors.lightGreen),
          SizedBox(width: 6),
          Text(
            'Watched',
            style: TextStyle(fontSize: 12, color: Colors.lightGreen),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          position.label,
          style: const TextStyle(fontSize: 12, color: AppColors.focus),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 220,
          child: LinearProgressIndicator(
            value: position.progress,
            minHeight: 3,
            backgroundColor: AppColors.surfaceHigh,
          ),
        ),
      ],
    );
  }
}

/// "Continue watching" block for the top of the Movies / Series pages.
class ContinueWatching extends ConsumerWidget {
  const ContinueWatching({
    super.key,
    required this.refPrefix,
    required this.onPlay,
    this.maxItems = 6,
  });

  /// `movie:` or `series:`.
  final String refPrefix;
  final PlayMedia onPlay;
  final int maxItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items =
        (ref.watch(resumeListProvider).valueOrNull ??
                const <PlaybackPosition>[])
            .where(
              (p) =>
                  p.ref.startsWith(refPrefix) && p.url.isNotEmpty && !p.watched,
            )
            .take(maxItems)
            .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'CONTINUE WATCHING',
            style: TextStyle(
              color: AppColors.accent,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        for (final (i, p) in items.indexed)
          ListTile(
            autofocus: i == 0,
            leading: SizedBox(
              width: 44,
              height: 60,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CoverImage(url: p.logo),
              ),
            ),
            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: ResumeProgress(position: p),
            trailing: IconButton(
              tooltip: 'Remove from Continue watching',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.read(databaseProvider).deletePosition(p.mediaId),
            ),
            onTap: () => onPlay(context, p.toMedia()),
          ),
        const Divider(height: 16),
      ],
    );
  }
}
