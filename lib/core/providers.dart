import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/app_settings.dart';
import 'app_config.dart';
import 'app_paths.dart';
import 'db/database.dart';
import 'log.dart';

/// Overridden in main() once paths/db/config are resolved.
final appPathsProvider = Provider<AppPaths>((ref) => throw UnimplementedError());
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());
final initialConfigProvider = Provider<(AppConfig, bool)>((ref) => throw UnimplementedError());
final initialSettingsProvider = Provider<AppSettings>((ref) => throw UnimplementedError());

class ConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() => ref.read(initialConfigProvider).$1;

  Future<void> update(AppConfig config) async {
    await AppConfig.save(ref.read(appPathsProvider).configFile, config);
    state = config;
  }
}

final configProvider = NotifierProvider<ConfigNotifier, AppConfig>(ConfigNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  Timer? _saveTimer;

  @override
  AppSettings build() {
    ref.onDispose(() => _saveTimer?.cancel());
    return ref.read(initialSettingsProvider);
  }

  void update(AppSettings Function(AppSettings s) change) {
    state = change(state);
    // Debounced so volume key repeats don't hammer the disk.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    try {
      await state.save(ref.read(appPathsProvider).settingsFile);
    } catch (e) {
      AppLog.w('Saving settings failed: $e');
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
