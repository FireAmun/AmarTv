import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../channels/widgets.dart';
import '../playlist/channel.dart';
import '../settings/app_settings.dart';
import '../xtream/epg.dart';
import 'player_controller.dart';

/// Video surface + overlays (status, channel banner, number entry, volume).
/// Contains no keyboard logic; the parent owns input.
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({
    super.key,
    required this.scale,
    this.numberBuffer = '',
    this.notice,
    this.showHint = false,
    this.showControls = false,
    this.infoTick = 0,
  });

  final UiScale scale;

  /// Digits being typed for numeric channel entry.
  final String numberBuffer;

  /// Short message such as "No channel 999".
  final String? notice;

  /// Show a one-line keyboard hint when nothing is playing.
  final bool showHint;

  /// Recent input: show the movie/episode progress bar.
  final bool showControls;

  /// Changes when the user asks for info (I key): shows the channel banner.
  final int infoTick;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  Timer? _bannerTimer;
  Timer? _volumeTimer;
  bool _showBanner = false;
  bool _showVolume = false;
  String? _pill;
  Timer? _pillTimer;

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _volumeTimer?.cancel();
    _pillTimer?.cancel();
    super.dispose();
  }

  void _flashBanner() {
    _bannerTimer?.cancel();
    setState(() => _showBanner = true);
    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showBanner = false);
    });
  }

  void _flashVolume() {
    _volumeTimer?.cancel();
    setState(() => _showVolume = true);
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolume = false);
    });
  }

  @override
  void didUpdateWidget(PlayerView old) {
    super.didUpdateWidget(old);
    if (old.infoTick != widget.infoTick) WidgetsBinding.instance.addPostFrameCallback((_) => _flashBanner());
  }

  void _flashPill(String text) {
    _pillTimer?.cancel();
    setState(() => _pill = text);
    _pillTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pill = null);
    });
  }

  static BoxFit _fit(ZoomMode z) => switch (z) {
        ZoomMode.fit => BoxFit.contain,
        ZoomMode.fill => BoxFit.cover,
        ZoomMode.stretch => BoxFit.fill,
      };

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(playerProvider.notifier);
    final zoom = ref.watch(settingsProvider.select((s) => s.zoom));
    ref.listen(settingsProvider.select((s) => s.zoom), (prev, next) {
      if (prev != next) _flashPill('Zoom: ${next.name[0].toUpperCase()}${next.name.substring(1)}');
    });
    final state = ref.watch(playerProvider);
    ref.listen(playerProvider.select((s) => s.channel?.id), (prev, next) {
      if (next != null && prev != next) _flashBanner();
    });
    ref.listen(playerProvider.select((s) => (s.volume, s.muted)), (prev, next) {
      if (prev != null && prev != next) _flashVolume();
    });

    final scale = widget.scale;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            child: Video(
              controller: controller.video,
              controls: NoVideoControls,
              fill: Colors.black,
              fit: _fit(zoom),
              // Wakelock and background handling live in PlayerController.
              wakelock: false,
              pauseUponEnteringBackgroundMode: false,
              // Bigger subtitles in TV mode (readable from the sofa).
              subtitleViewConfiguration: SubtitleViewConfiguration(
                style: TextStyle(
                  fontSize: scale.tv ? 46 : 32,
                  height: 1.4,
                  color: Colors.white,
                  backgroundColor: const Color(0xAA000000),
                ),
              ),
            ),
          ),
          if (state.channel == null)
            Center(
              child: Text(
                widget.showHint ? 'Pick a channel  -  Enter: list   0-9: number' : 'Pick a channel',
                style: const TextStyle(color: AppColors.textDim, fontSize: 18),
              ),
            ),
          if (state.status != PlayerStatus.playing && state.status != PlayerStatus.idle)
            Center(child: _StatusBox(state: state, onRetry: controller.retry)),
          if (state.upNext != null)
            Center(child: _UpNextCard(next: state.upNext!, controller: controller, scale: scale))
          else if (state.status == PlayerStatus.idle && state.message != null)
            Center(child: _StatusBox(state: state, onRetry: controller.retry)),
          if (!state.isVod && state.liveLag != null && state.status == PlayerStatus.playing)
            Positioned(top: 16, right: 20, child: _LiveBadge(lag: state.liveLag!, onJump: controller.jumpToLive)),
          if (_showBanner && state.channel != null)
            Positioned(
              left: 24,
              bottom: 24,
              child: _ChannelBanner(channel: state.channel!, scale: scale),
            ),
          if (widget.numberBuffer.isNotEmpty || widget.notice != null)
            Positioned(
              top: 24,
              right: 32,
              child: _Pill(
                text: widget.numberBuffer.isNotEmpty ? widget.numberBuffer : widget.notice!,
                fontSize: widget.numberBuffer.isNotEmpty ? (scale.tv ? 72 : 56) : 22,
              ),
            ),
          if (state.resumedFrom != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.history, color: AppColors.focus),
                    const SizedBox(width: 10),
                    Text('Continuing from ${_VodBar._fmt(state.resumedFrom!)}',
                        style: TextStyle(fontSize: scale.tv ? 24 : 18, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 16),
                    ExcludeFocus(
                      child: TextButton.icon(
                        onPressed: controller.restart,
                        icon: const Icon(Icons.replay),
                        label: Text(widget.showHint ? 'Start over (R)' : 'Start over'),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          if (_pill != null)
            Positioned(top: 24, left: 0, right: 0, child: Center(child: _Pill(text: _pill!, fontSize: scale.tv ? 28 : 20))),
          if (state.isVod && (state.paused || widget.showControls) && state.status == PlayerStatus.playing)
            Positioned(left: 24, right: 24, bottom: 20, child: _VodBar(controller: controller, paused: state.paused)),
          if (_showVolume)
            Positioned(
              top: 24,
              left: 24,
              child: _Pill(
                text: state.muted ? 'Muted' : 'Volume ${state.volume.round()}',
                fontSize: scale.tv ? 28 : 20,
              ),
            ),
          if (state.sleepAt != null)
            Positioned(
              right: 12,
              bottom: 12,
              child: Icon(Icons.bedtime_outlined, color: Colors.white.withValues(alpha: 0.5)),
            ),
        ],
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.state, required this.onRetry});
  final PlayerUiState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (title, busy) = switch (state.status) {
      PlayerStatus.connecting => ('Connecting...', true),
      PlayerStatus.buffering => ('Buffering...', true),
      PlayerStatus.reconnecting => ('Reconnecting', true),
      PlayerStatus.unavailable => ('Stream unavailable', false),
      _ => ('Stopped', false),
    };
    final canRetry = state.status == PlayerStatus.unavailable ||
        state.status == PlayerStatus.reconnecting ||
        state.status == PlayerStatus.idle;
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          if (busy) const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          if (state.message != null) ...[
            const SizedBox(height: 8),
            Text(state.message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
          ],
          if (canRetry) ...[
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}

class _ChannelBanner extends StatelessWidget {
  const _ChannelBanner({required this.channel, required this.scale});
  final Channel channel;
  final UiScale scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChannelLogo(channel: channel, size: scale.tv ? 72 : 52),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (channel.number > 0) ...[
                  Text('${channel.number}', style: TextStyle(fontSize: scale.tv ? 34 : 26, color: AppColors.focus)),
                  const SizedBox(width: 14),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: scale.tv ? 34 : 26, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              EpgNowNextBlock(channel: channel, large: scale.tv),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.fontSize});
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600)),
    );
  }
}

/// Position / duration bar for movies and episodes.
class _VodBar extends StatelessWidget {
  const _VodBar({required this.controller, required this.paused});
  final PlayerController controller;
  final bool paused;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = controller.player;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(10)),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, snap) {
          final pos = snap.data ?? Duration.zero;
          final dur = player.state.duration;
          final value = dur.inMilliseconds <= 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
          return Row(
            children: [
              Icon(paused ? Icons.pause : Icons.play_arrow),
              const SizedBox(width: 10),
              Text(_fmt(pos)),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 4, overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(
                    value: value,
                    onChanged: dur.inMilliseconds <= 0
                        ? null
                        : (v) => controller.seekBy(Duration(milliseconds: (v * dur.inMilliseconds).round()) - pos),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(_fmt(dur)),
            ],
          );
        },
      ),
    );
  }
}

/// "LIVE" when close to real time, otherwise how far behind (tap / L = jump).
class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.lag, required this.onJump});
  final Duration lag;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final live = lag < const Duration(seconds: 6);
    final m = lag.inMinutes;
    final sec = lag.inSeconds.remainder(60).toString().padLeft(2, '0');
    return ExcludeFocus(
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: live ? null : onJump,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 10, color: live ? AppColors.danger : AppColors.focus),
              const SizedBox(width: 6),
              Text(
                live ? 'LIVE' : '-$m:$sec  (L = go live)',
                style: TextStyle(fontWeight: FontWeight.w700, color: live ? Colors.white : AppColors.focus),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// After an episode: "Next episode in 10" with Play now / Cancel.
class _UpNextCard extends StatefulWidget {
  const _UpNextCard({required this.next, required this.controller, required this.scale});
  final Channel next;
  final PlayerController controller;
  final UiScale scale;

  @override
  State<_UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<_UpNextCard> {
  late int _left = PlayerController.upNextDelay.inSeconds;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left > 0) setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final big = widget.scale.tv;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ChannelLogo(channel: widget.next, size: big ? 90 : 64),
        const SizedBox(width: 16),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Next episode in $_left',
                style: TextStyle(color: AppColors.focus, fontSize: big ? 20 : 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(widget.next.name,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: big ? 24 : 18)),
            const SizedBox(height: 12),
            Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                onPressed: widget.controller.playUpNext,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play now'),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: widget.controller.cancelUpNext, child: const Text('Cancel')),
            ]),
          ]),
        ),
      ]),
    );
  }
}
