import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where AmarTv keeps its writable files.
///
/// Windows (portable): `<exe dir>/data/amartv/` and `<exe dir>/config.json`,
/// falling back to `%LOCALAPPDATA%/AmarTv` when the exe folder is read-only.
/// Android: the app's private support directory.
class AppPaths {
  AppPaths({
    required this.dataDir,
    required this.configFile,
    required this.exampleConfigFile,
    this.warning,
  });

  final Directory dataDir;
  final File configFile;
  final File? exampleConfigFile;

  /// Set when data could not be stored next to the exe.
  final String? warning;

  File get databaseFile => File(p.join(dataDir.path, 'amartv.sqlite'));
  File get settingsFile => File(p.join(dataDir.path, 'settings.json'));
  Directory get logoCacheDir => Directory(p.join(dataDir.path, 'logos'));
  Directory get logDir => Directory(p.join(dataDir.path, 'logs'));

  static Future<AppPaths> resolve() async {
    if (!Platform.isWindows) {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      return AppPaths(
        dataDir: dir,
        configFile: File(p.join(dir.path, 'config.json')),
        exampleConfigFile: null,
      );
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final portable = Directory(p.join(exeDir, 'data', 'amartv'));
    final example = File(p.join(exeDir, 'config.example.json'));
    if (await _isWritable(portable)) {
      return AppPaths(
        dataDir: portable,
        configFile: File(p.join(exeDir, 'config.json')),
        exampleConfigFile: example,
      );
    }

    final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final fallback = Directory(p.join(local, 'AmarTv'));
    await fallback.create(recursive: true);
    final exeConfig = File(p.join(exeDir, 'config.json'));
    return AppPaths(
      dataDir: fallback,
      // Still prefer a config.json shipped next to the exe (read-only is fine).
      configFile: await exeConfig.exists() ? exeConfig : File(p.join(fallback.path, 'config.json')),
      exampleConfigFile: example,
      warning: 'The app folder is read-only, so data is saved in ${fallback.path} '
          'and will not travel with the folder.',
    );
  }

  static Future<bool> _isWritable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
