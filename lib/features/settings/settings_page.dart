import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/logo_cache.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/url_mask.dart';
import '../../core/windows_startup.dart';
import '../channels/group_setup_page.dart';
import '../player/player_controller.dart';
import '../playlist/playlist_controller.dart';
import '../remote/remote_page.dart';
import '../remote/remote_server.dart';
import '../xtream/xtream_api.dart';
import '../xtream/xtream_models.dart';
import 'app_settings.dart';

/// Opens Settings, asking for the parental PIN first when one is set.
Future<void> openSettings(BuildContext context, WidgetRef ref) async {
  final pin = ref.read(settingsProvider).pin;
  if (pin.isNotEmpty) {
    final entered = await _askPin(context, 'Enter PIN');
    if (entered != pin) {
      if (entered != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong PIN')));
      }
      return;
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
}

Future<String?> _askPin(BuildContext context, String title) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
      ],
    ),
  );
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.embedded = false});

  /// Shown as a tab (phone) instead of a pushed page.
  final bool embedded;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _ua;
  bool _showUrl = false;
  bool _startup = WindowsStartup.isEnabled;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configProvider);
    _url = TextEditingController(text: config.isConfigured ? config.playlistUrl : '');
    _ua = TextEditingController(text: config.userAgent);
    _showUrl = !config.isConfigured;
  }

  @override
  void dispose() {
    _url.dispose();
    _ua.dispose();
    super.dispose();
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _savePlaylist() async {
    final config = AppConfig(playlistUrl: _url.text.trim(), userAgent: _ua.text.trim());
    if (!config.isConfigured) {
      _toast('Enter a valid http(s) playlist URL.');
      return;
    }
    try {
      await ref.read(configProvider.notifier).update(config);
      setState(() => _showUrl = false);
      _toast('Saved. Loading playlist...');
    } catch (e) {
      _toast(maskUrl('Could not save config.json: $e'));
    }
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cache?'),
        content: const Text('Removes the saved channel list and logos, then downloads the playlist again. '
            'Favorites and history are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(playlistProvider.notifier).clearCache();
    await LogoCache.clear();
    _toast('Cache cleared.');
    await ref.read(playlistProvider.notifier).refresh();
  }

  Future<void> _toggleStartup(bool enable) async {
    if (enable) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start with Windows?'),
          content: Text('A shortcut to\n${Platform.resolvedExecutable}\nwill be added to your Startup folder. '
              'If you move the app folder or the USB drive letter changes, turn this off and on again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final success = await WindowsStartup.setEnabled(enable);
    if (!success) _toast('Could not change the startup shortcut.');
    setState(() => _startup = WindowsStartup.isEnabled);
  }

  Future<void> _editGroups() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GroupSetupPage()));

  Future<void> _editPin() async {
    final current = ref.read(settingsProvider).pin;
    if (current.isNotEmpty) {
      final remove = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Parental PIN'),
          content: const Text('Change or remove the PIN?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
            FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Change')),
          ],
        ),
      );
      if (remove == null) return;
      if (remove) {
        ref.read(settingsProvider.notifier).update((s) => s.copyWith(pin: ''));
        _toast('PIN removed.');
        return;
      }
    }
    if (!mounted) return;
    final pin = await _askPin(context, 'New PIN (4-8 digits)');
    if (pin == null) return;
    if (pin.length < 4) {
      _toast('The PIN must have at least 4 digits.');
      return;
    }
    if (!mounted) return;
    final again = await _askPin(context, 'Repeat PIN');
    if (again != pin) {
      _toast('PINs do not match.');
      return;
    }
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(pin: pin));
    _toast('PIN set. Settings are now protected.');
  }

  Future<void> _sleepTimer() async {
    const options = [0, 15, 30, 60, 90, 120];
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sleep timer'),
        children: [
          for (final m in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: Text(m == 0 ? 'Off' : '$m minutes'),
            ),
        ],
      ),
    );
    if (minutes == null) return;
    ref.read(playerProvider.notifier).setSleepTimer(minutes == 0 ? null : Duration(minutes: minutes));
  }

  Future<void> _audioTrack() async {
    final state = ref.read(playerProvider);
    if (state.audioTracks.isEmpty) {
      _toast('No audio tracks (start a channel first).');
      return;
    }
    final track = await showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Audio track'),
        children: [
          for (final t in state.audioTracks)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Text(
                [t.title, t.language, t.codec].whereType<String>().where((s) => s.isNotEmpty).join(' - ').ifEmpty('Track ${t.id}'),
                style: TextStyle(fontWeight: t == state.audioTrack ? FontWeight.bold : FontWeight.normal),
              ),
            ),
        ],
      ),
    );
    if (track != null) await ref.read(playerProvider.notifier).setAudioTrack(track);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final config = ref.watch(configProvider);
    final playlist = ref.watch(playlistProvider);
    final player = ref.watch(playerProvider);
    final paths = ref.read(appPathsProvider);
    final isWindows = Platform.isWindows;

    final body = ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        const _Section('Playlist'),
        if (_showUrl) ...[
          TextField(
            controller: _url,
            autofocus: !config.isConfigured,
            decoration: const InputDecoration(
              labelText: 'M3U playlist URL',
              hintText: 'http://host/get.php?username=...&password=...&type=m3u_plus&output=ts',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ua,
            decoration: const InputDecoration(
              labelText: 'User-Agent (optional)',
              hintText: 'Leave empty unless the provider needs it',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(onPressed: _savePlaylist, child: const Text('Save')),
            const SizedBox(width: 8),
            if (config.isConfigured)
              TextButton(onPressed: () => setState(() => _showUrl = false), child: const Text('Cancel')),
          ]),
        ] else
          ListTile(
            title: const Text('Playlist URL'),
            subtitle: Text(maskUrl(config.playlistUrl), maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.edit),
            onTap: () => setState(() => _showUrl = true),
          ),
        ListTile(
          title: const Text('Refresh now'),
          subtitle: Text(
            '${playlist.channels.length} channels'
            '${settings.lastRefresh != null ? '  -  updated ${_ago(settings.lastRefresh!)}' : ''}',
          ),
          trailing: playlist.refreshing
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          onTap: playlist.refreshing ? null : () => ref.read(playlistProvider.notifier).refresh(),
        ),
        if (playlist.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(playlist.error!, style: const TextStyle(color: AppColors.danger)),
          ),
        ListTile(
          title: const Text('Clear cache'),
          subtitle: const Text('Channel list and logos'),
          trailing: const Icon(Icons.delete_outline),
          onTap: _clearCache,
        ),
        SwitchListTile(
          title: const Text('Include movies & series'),
          subtitle: const Text('Show VOD entries from the playlist as extra groups'),
          value: settings.includeVod,
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(includeVod: v)),
        ),
        ListTile(
          title: const Text('Choose groups'),
          subtitle: Text(settings.hiddenGroups.isEmpty ? 'All groups shown' : '${settings.hiddenGroups.length} groups hidden'),
          trailing: const Icon(Icons.checklist),
          onTap: _editGroups,
        ),
        SwitchListTile(
          title: const Text('Favorite quick numbers'),
          subtitle: const Text('Number keys 1, 2, 3... pick your favorites in your order'),
          value: settings.favoriteNumbers,
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(favoriteNumbers: v)),
        ),
        if (ref.watch(xtreamApiProvider) != null) ...[
          const _Section('Subscription'),
          _AccountTile(onRefresh: () => ref.invalidate(accountProvider)),
        ],
        const _Section('Playback'),
        RadioListTile<PlaybackProfile>(
          value: PlaybackProfile.auto,
          groupValue: settings.profile,
          title: const Text('Auto'),
          subtitle: const Text('Hardware decoding with software fallback, moderate buffer'),
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(profile: v)),
        ),
        RadioListTile<PlaybackProfile>(
          value: PlaybackProfile.compatibility,
          groupValue: settings.profile,
          title: const Text('Compatibility'),
          subtitle: const Text('Software decoding, small buffer - for old hardware or green/black video'),
          onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(profile: v)),
        ),
        ListTile(
          title: const Text('Audio track'),
          subtitle: Text(player.audioTrack == null ? 'Auto' : (player.audioTrack!.language ?? player.audioTrack!.id)),
          trailing: const Icon(Icons.audiotrack_outlined),
          onTap: _audioTrack,
        ),
        ListTile(
          title: const Text('Picture'),
          subtitle: Text(switch (settings.zoom) {
            ZoomMode.fit => 'Fit (whole picture, black bars)',
            ZoomMode.fill => 'Fill (crop edges, no bars)',
            ZoomMode.stretch => 'Stretch (fill, may distort)',
          }),
          trailing: const Icon(Icons.aspect_ratio),
          onTap: () => ref.read(settingsProvider.notifier).update(
              (s) => s.copyWith(zoom: ZoomMode.values[(s.zoom.index + 1) % ZoomMode.values.length])),
        ),
        ListTile(
          title: const Text('Sleep timer'),
          subtitle: Text(player.sleepAt == null ? 'Off' : 'Stops at ${TimeOfDay.fromDateTime(player.sleepAt!).format(context)}'),
          trailing: const Icon(Icons.bedtime_outlined),
          onTap: _sleepTimer,
        ),
        if (isWindows) ...[
          const _Section('Windows'),
          SwitchListTile(
            title: const Text('TV mode'),
            subtitle: const Text('Start fullscreen, auto-play last channel, large text, keyboard only'),
            value: settings.tvMode,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(tvMode: v)),
          ),
          SwitchListTile(
            title: const Text('Start with Windows'),
            subtitle: const Text('Adds a shortcut to your Startup folder'),
            value: _startup,
            onChanged: _toggleStartup,
          ),
          SwitchListTile(
            title: const Text('Phone remote'),
            subtitle: const Text('Control this PC from the AmarTv app on your phone (same Wi-Fi). '
                'Windows may ask to allow network access - choose Private networks.'),
            value: settings.remoteEnabled,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(remoteEnabled: v)),
          ),
          if (settings.remoteEnabled) _RemoteInfoTile(code: settings.remoteCode),
        ] else ...[
          const _Section('Remote'),
          ListTile(
            title: const Text('Use this phone as a remote'),
            subtitle: const Text('Control AmarTv on a PC over Wi-Fi'),
            trailing: const Icon(Icons.settings_remote_outlined),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemotePage())),
          ),
        ],
        const _Section('Parental control'),
        ListTile(
          title: const Text('Parental PIN'),
          subtitle: Text(settings.pin.isEmpty ? 'Off' : 'On - Settings need the PIN (hidden groups stay hidden)'),
          trailing: const Icon(Icons.lock_outline),
          onTap: _editPin,
        ),
        const _Section('About'),
        ListTile(
          title: const Text('Data folder'),
          subtitle: Text(paths.dataDir.path + (paths.warning != null ? '\n${paths.warning}' : '')),
        ),
        if (isWindows)
          const ListTile(
            title: Text('Keyboard'),
            subtitle: Text('Up/Down channel  -  Left/Right volume (movies: seek)  -  Enter list/select  -  Esc close  -  '
                'Backspace last channel  -  F fullscreen  -  M mute  -  Z zoom  -  I info  -  S series  -  '
                'Space pause (movies)  -  Tab list  -  Ctrl+F search  -  0-9 number  -  +/- volume'),
          ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Settings')), body: body);
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, letterSpacing: 1)),
      );
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.onRefresh});
  final VoidCallback onRefresh;

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return account.when(
      loading: () => const ListTile(title: Text('Checking subscription...')),
      error: (_, _) => ListTile(title: const Text('Subscription status unavailable'), onTap: onRefresh),
      data: (AccountInfo? info) {
        if (info == null) {
          return ListTile(
            title: const Text('Subscription status unavailable'),
            trailing: const Icon(Icons.refresh),
            onTap: onRefresh,
          );
        }
        final left = info.remaining;
        final expiry = info.expires == null
            ? 'No expiry date'
            : 'Expires ${_date(info.expires!)}${left != null && !left.isNegative ? ' (${left.inDays} days left)' : ''}';
        final cons = info.maxConnections == null
            ? ''
            : '\nConnections in use: ${info.activeConnections ?? 0} of ${info.maxConnections}';
        final warn = !info.isActive || (left != null && left.inDays < 7);
        return ListTile(
          title: Text('Status: ${info.status}${info.isTrial ? ' (trial)' : ''}',
              style: TextStyle(color: warn ? AppColors.danger : null)),
          subtitle: Text('$expiry$cons'),
          trailing: const Icon(Icons.refresh),
          onTap: onRefresh,
        );
      },
    );
  }
}

class _RemoteInfoTile extends StatelessWidget {
  const _RemoteInfoTile({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: RemoteServer.localAddresses(),
      builder: (context, snap) {
        final ips = snap.data ?? const [];
        return ListTile(
          leading: const Icon(Icons.phonelink_ring),
          title: Text('Code: $code', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          subtitle: Text(ips.isEmpty
              ? 'On the phone: AmarTv > Remote. This PC should appear automatically.'
              : 'On the phone: AmarTv > Remote. This PC: ${ips.join(', ')}'),
        );
      },
    );
  }
}
