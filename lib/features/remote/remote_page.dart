import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import 'remote_server.dart';

/// Phone side of the remote: find the PC, enter its code, then press buttons.
class RemotePage extends ConsumerStatefulWidget {
  const RemotePage({super.key});

  @override
  ConsumerState<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends ConsumerState<RemotePage> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
    validateStatus: (_) => true,
  ));
  final _found = <String, String>{}; // address -> pc name
  bool _searching = false;
  bool _connected = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final parts = ref.read(settingsProvider).remoteTarget.split('|');
    if (parts.length == 2) {
      _host.text = parts[0];
      _code.text = parts[1];
    }
    _discover();
  }

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    _dio.close(force: true);
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _searching = true;
      _found.clear();
    });
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket?.receive();
        if (d == null) return;
        final text = utf8.decode(d.data, allowMalformed: true);
        if (text.startsWith('AMARTV|') && mounted) {
          setState(() => _found[d.address.address] = text.substring(7));
        }
      });
      final msg = utf8.encode(RemoteServer.discoveryRequest);
      for (var i = 0; i < 3; i++) {
        socket.send(msg, InternetAddress('255.255.255.255'), RemoteServer.discoveryPort);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } catch (_) {
      // No network / broadcast blocked: manual entry still works.
    } finally {
      socket?.close();
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final code = _code.text.trim();
    if (host.isEmpty || code.isEmpty) return;
    setState(() => _status = 'Connecting...');
    final ok = await _send(null);
    if (ok) {
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(remoteTarget: '$host|$code'));
      setState(() => _connected = true);
    }
  }

  /// Sends a command (or just reads the state when [command] is null).
  Future<bool> _send(String? command) async {
    if (command != null) HapticFeedback.lightImpact();
    final host = _host.text.trim();
    final code = _code.text.trim();
    final path = command == null ? 'state' : 'cmd';
    try {
      final res = await _dio.get<dynamic>('http://$host:${RemoteServer.httpPort}/api/$path',
          queryParameters: {'code': code, if (command != null) 'c': command});
      if (res.statusCode == 403) {
        setState(() => _status = 'Wrong code - check Settings > Phone remote on the PC.');
        return false;
      }
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is Map) {
        final number = data['number'];
        final name = data['channel'];
        setState(() => _status = name == null ? 'Connected' : '${number ?? ''}  $name'.trim());
      }
      return res.statusCode == 200;
    } catch (_) {
      setState(() => _status = 'PC not reachable. Same Wi-Fi? Phone remote on in the PC Settings?');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote'),
        actions: [
          if (_connected)
            TextButton(onPressed: () => setState(() => _connected = false), child: const Text('Change PC')),
        ],
      ),
      body: _connected ? _remote() : _setup(),
    );
  }

  Widget _setup() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Control AmarTv on a PC. On the PC: Settings > Phone remote > On. '
            'Phone and PC must be on the same Wi-Fi.'),
        const SizedBox(height: 16),
        Row(children: [
          const Text('PCs found', style: TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          if (_searching)
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            TextButton(onPressed: _discover, child: const Text('Search again')),
        ]),
        if (_found.isEmpty && !_searching)
          const Text('None found - type the PC address below.', style: TextStyle(color: AppColors.textDim)),
        for (final e in _found.entries)
          ListTile(
            leading: const Icon(Icons.computer),
            title: Text(e.value),
            subtitle: Text(e.key),
            selected: _host.text == e.key,
            onTap: () => setState(() => _host.text = e.key),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _host,
          decoration: const InputDecoration(labelText: 'PC address (e.g. 192.168.1.20)', border: OutlineInputBorder()),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          decoration: const InputDecoration(labelText: 'Code shown on the PC', border: OutlineInputBorder()),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _connect, child: const Text('Connect')),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(color: AppColors.textDim)),
        ],
      ],
    );
  }

  Widget _btn(String command, IconData icon, {String? label, double size = 64}) => SizedBox.square(
        dimension: size,
        child: IconButton.filledTonal(
          tooltip: label,
          iconSize: size * 0.45,
          onPressed: () => _send(command),
          icon: Icon(icon),
        ),
      );

  Widget _digit(int d) => SizedBox(
        width: 72,
        height: 52,
        child: FilledButton.tonal(onPressed: () => _send('d$d'), child: Text('$d', style: const TextStyle(fontSize: 20))),
      );

  Widget _remote() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_status, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 16),
        // D-pad: in the list it moves; on the video Up/Down = channel, Left/Right = volume.
        Column(children: [
          _btn('up', Icons.keyboard_arrow_up, label: 'Up'),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _btn('left', Icons.keyboard_arrow_left, label: 'Left'),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 72,
              child: FilledButton(onPressed: () => _send('ok'), child: const Text('OK', style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 8),
            _btn('right', Icons.keyboard_arrow_right, label: 'Right'),
          ]),
          _btn('down', Icons.keyboard_arrow_down, label: 'Down'),
        ]),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _btn('back', Icons.arrow_back, label: 'Back', size: 56),
          _btn('list', Icons.list, label: 'Channel list', size: 56),
          _btn('last', Icons.history, label: 'Last channel', size: 56),
          _btn('info', Icons.info_outline, label: 'Info', size: 56),
          _btn('live', Icons.sensors, label: 'Go live', size: 56),
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          Column(children: [
            _btn('volup', Icons.volume_up, label: 'Volume up', size: 56),
            _btn('voldown', Icons.volume_down, label: 'Volume down', size: 56),
          ]),
          Column(children: [
            _btn('mute', Icons.volume_off, label: 'Mute', size: 56),
            _btn('zoom', Icons.aspect_ratio, label: 'Zoom', size: 56),
            _btn('playpause', Icons.play_arrow, label: 'Play/pause (movies)', size: 56),
            _btn('restart', Icons.replay, label: 'Start over (movies)', size: 56),
          ]),
          Column(children: [
            _btn('chup', Icons.add, label: 'Channel up', size: 56),
            _btn('chdown', Icons.remove, label: 'Channel down', size: 56),
          ]),
        ]),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [for (final d in [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]) _digit(d)],
        ),
      ],
    );
  }
}
