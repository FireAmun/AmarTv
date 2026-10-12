import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'url_mask.dart';

/// Tiny logger: debug console + `data/amartv/logs/amartv.log` (rotated at
/// 1 MB). Every message is passed through [maskUrl] first.
class AppLog {
  AppLog._();

  static const _maxBytes = 1024 * 1024;
  static File? _file;

  static void init(Directory dir) {
    try {
      dir.createSync(recursive: true);
      final file = File(p.join(dir.path, 'amartv.log'));
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.renameSync(p.join(dir.path, 'amartv.old.log'));
      }
      _file = File(p.join(dir.path, 'amartv.log'));
    } catch (_) {
      _file = null;
    }
  }

  static void i(String message) => _write('INFO', message);
  static void w(String message) => _write('WARN', message);
  static void e(String message) => _write('ERROR', message);

  static void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} $level ${maskUrl(message)}';
    debugPrint(line);
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never break the app.
    }
  }
}
