import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/providers.dart';
import '../player/player_controller.dart';

/// Phone-as-remote, PC side (Windows only, off by default).
///
/// HTTP on [httpPort]: `GET /api/cmd?c=<command>&code=<pairing code>` and
/// `GET /api/state?code=...`. UDP on [discoveryPort]: answers `AMARTV?` with
/// `AMARTV|<pc name>` so the phone can find the PC.
class RemoteServer {
  RemoteServer({required this.code, required this.onCommand, required this.state});

  static const httpPort = 47800;
  static const discoveryPort = 47801;
  static const discoveryRequest = 'AMARTV?';

  /// Commands understood by [onCommand].
  static const commands = {
    'up', 'down', 'left', 'right', 'ok', 'back', 'list', 'chup', 'chdown', 'volup', 'voldown', //
    'mute', 'zoom', 'playpause', 'last', 'info', 'd0', 'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'd8', 'd9',
  };

  final String code;
  final void Function(String command) onCommand;
  final Map<String, Object?> Function() state;

  HttpServer? _http;
  RawDatagramSocket? _udp;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
    _http!.listen(_handle, onError: (Object e) => AppLog.w('Remote HTTP: $e'));
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = _udp?.receive();
        if (d == null || utf8.decode(d.data, allowMalformed: true).trim() != discoveryRequest) return;
        _udp?.send(utf8.encode('AMARTV|${Platform.localHostname}'), d.address, d.port);
      });
    } catch (e) {
      AppLog.w('Remote discovery unavailable: $e');
    }
    AppLog.i('Phone remote listening on port $httpPort');
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _udp?.close();
    _http = null;
    _udp = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.contentType = ContentType.json;
    try {
      final q = req.uri.queryParameters;
      if (req.uri.path == '/api/hello') {
        res.write(jsonEncode({'app': 'AmarTv', 'name': Platform.localHostname}));
      } else if (q['code'] != code) {
        res.statusCode = HttpStatus.forbidden;
        res.write(jsonEncode({'error': 'wrong code'}));
      } else if (req.uri.path == '/api/cmd' && commands.contains(q['c'])) {
        onCommand(q['c']!);
        // Give the app a moment so the reply shows the new channel.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        res.write(jsonEncode(state()));
      } else if (req.uri.path == '/api/state') {
        res.write(jsonEncode(state()));
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
    }
    await res.close();
  }

  /// This PC's LAN addresses, for showing in Settings.
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// Commands from the phone remote; the desktop home turns them into actions.
final remoteCommandsProvider = Provider<StreamController<String>>((ref) {
  final controller = StreamController<String>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// Runs the server while "Phone remote" is on (Windows only).
final remoteServerProvider = FutureProvider<bool>((ref) async {
  if (!Platform.isWindows) return false;
  final enabled = ref.watch(settingsProvider.select((s) => s.remoteEnabled));
  final code = ref.watch(settingsProvider.select((s) => s.remoteCode));
  if (!enabled) return false;
  final server = RemoteServer(
    code: code,
    onCommand: ref.read(remoteCommandsProvider).add,
    state: () {
      final p = ref.read(playerProvider);
      return {
        'channel': p.channel?.name,
        'number': p.channel?.number,
        'status': p.status.name,
        'volume': p.volume.round(),
        'muted': p.muted,
      };
    },
  );
  ref.onDispose(server.stop);
  try {
    await server.start();
    return true;
  } catch (e) {
    AppLog.w('Phone remote could not start: $e');
    return false;
  }
});
