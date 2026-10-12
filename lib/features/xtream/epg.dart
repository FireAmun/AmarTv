import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import '../playlist/channel.dart';
import 'xtream_api.dart';
import 'xtream_models.dart';

bool isVodUrl(String url) => RegExp(r'/(movie|series)/', caseSensitive: false).hasMatch(url);

/// Short EPG for one Xtream stream id. Fetched lazily (only for rows on
/// screen), kept until the current programme ends (max 15 min).
final epgProvider = FutureProvider.autoDispose.family<List<EpgProgram>, int>((ref, streamId) async {
  final api = ref.watch(xtreamApiProvider);
  if (api == null) return const [];
  var disposed = false;
  ref.onDispose(() => disposed = true);
  // Rows flying past while scrolling are disposed before this ends: no request.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  if (disposed) return const [];

  List<EpgProgram> programs;
  try {
    programs = await api.shortEpg(streamId);
  } catch (e) {
    AppLog.w('EPG $streamId failed: $e');
    programs = const [];
  }
  final link = ref.keepAlive();
  final now = DateTime.now();
  final current = nowNextAt(programs, now).now;
  var ttl = const Duration(minutes: 15);
  if (current != null && current.end.difference(now) < ttl) {
    ttl = current.end.difference(now) + const Duration(seconds: 5);
  }
  final timer = Timer(ttl, () {
    link.close();
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return programs;
});

NowNext? watchNowNext(WidgetRef ref, Channel channel) {
  if (isVodUrl(channel.url)) return null;
  final id = streamIdFromUrl(channel.url);
  if (id == null || ref.watch(xtreamApiProvider) == null) return null;
  final programs = ref.watch(epgProvider(id)).valueOrNull;
  if (programs == null || programs.isEmpty) return null;
  return nowNextAt(programs, DateTime.now());
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One dim line under a channel name: "Now: Title".
class EpgNowLine extends ConsumerWidget {
  const EpgNowLine({super.key, required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = watchNowNext(ref, channel);
    final now = nn?.now;
    if (now == null) return const SizedBox.shrink();
    return Text(
      now.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: AppColors.textDim),
    );
  }
}

/// Now/next block for the channel banner, with a progress bar.
class EpgNowNextBlock extends ConsumerWidget {
  const EpgNowNextBlock({super.key, required this.channel, this.large = false});
  final Channel channel;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = watchNowNext(ref, channel);
    if (nn == null || nn.isEmpty) return const SizedBox.shrink();
    final size = large ? 20.0 : 15.0;
    final t = DateTime.now();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (nn.now != null) ...[
            Text(
              '${_hm(nn.now!.start)} - ${_hm(nn.now!.end)}   ${nn.now!.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: size, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 260,
              child: LinearProgressIndicator(
                value: nn.now!.progressAt(t),
                minHeight: 4,
                backgroundColor: AppColors.surfaceHigh,
              ),
            ),
          ],
          if (nn.next != null) ...[
            const SizedBox(height: 6),
            Text(
              'Next  ${_hm(nn.next!.start)}   ${nn.next!.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: size - 2, color: AppColors.textDim),
            ),
          ],
        ],
      ),
    );
  }
}
