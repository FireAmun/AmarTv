import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'player_controller.dart';

String trackLabel(String? language, String? title, String? codec, String id) {
  final parts = [language, title, codec].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty);
  return parts.isEmpty ? 'Track $id' : parts.join(' - ');
}

/// Subtitle choice for the current movie/episode. The language you pick is
/// remembered and chosen automatically for the next one.
Future<void> showSubtitlePicker(BuildContext context, WidgetRef ref) async {
  final state = ref.read(playerProvider);
  if (state.subtitleTracks.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('This video has no subtitles.')),
    );
    return;
  }
  final current = state.subtitleTrack;
  final off = current == null || current.id == 'no';
  final picked = await showDialog<(SubtitleTrack?,)>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Subtitles'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, (null,)),
          child: Text('Off', style: TextStyle(fontWeight: off ? FontWeight.bold : FontWeight.normal)),
        ),
        for (final t in state.subtitleTracks)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, (t,)),
            child: Text(
              trackLabel(t.language, t.title, t.codec, t.id),
              style: TextStyle(fontWeight: t == current ? FontWeight.bold : FontWeight.normal),
            ),
          ),
      ],
    ),
  );
  if (picked != null) await ref.read(playerProvider.notifier).setSubtitle(picked.$1);
}
