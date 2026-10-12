import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'core/app_paths.dart';
import 'core/db/database.dart';
import 'core/log.dart';
import 'core/logo_cache.dart';
import 'core/providers.dart';
import 'features/settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final paths = await AppPaths.resolve();
  AppLog.init(paths.logDir);
  AppLog.i('AmarTv starting, data: ${paths.dataDir.path}');
  if (paths.warning != null) AppLog.w(paths.warning!);

  FlutterError.onError = (details) {
    AppLog.e('Flutter: ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.e('Uncaught: $error\n$stack');
    return true;
  };

  if (Platform.isAndroid) await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
  LogoCache.init(paths.logoCacheDir);

  final config = await AppConfig.load(paths.configFile, paths.exampleConfigFile);
  final settings = await AppSettings.load(paths.settingsFile);
  final db = AppDatabase(paths.databaseFile);

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'AmarTv',
      size: Size(1280, 720),
      minimumSize: Size(960, 540),
      center: true,
      backgroundColor: Colors.black,
    );
    unawaited(windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
      // TV mode starts fullscreen. Must happen after show(): going fullscreen
      // earlier leaves a blank white window.
      if (settings.tvMode) await windowManager.setFullScreen(true);
    }));
  }

  final needsSetup = config.$2 || !config.$1.isConfigured;
  runApp(ProviderScope(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      databaseProvider.overrideWithValue(db),
      initialConfigProvider.overrideWithValue(config),
      initialSettingsProvider.overrideWithValue(settings),
    ],
    child: AmarApp(openSettingsOnStart: needsSetup),
  ));
}
