import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/log.dart';

enum PlaybackProfile {
  /// Hardware decoding with automatic software fallback, moderate buffer.
  auto,

  /// Software decoding, conservative buffer - for old hardware.
  compatibility,
}

/// How the video fills the screen (Z key).
enum ZoomMode { fit, fill, stretch }

/// User settings, stored as JSON in `data/amartv/settings.json` so they travel
/// with the portable folder (shared_preferences would write to %APPDATA%).
class AppSettings {
  const AppSettings({
    this.tvMode = true,
    this.profile = PlaybackProfile.auto,
    this.hiddenGroups = const {},
    this.groupsConfigured = false,
    this.pin = '',
    this.volume = 100,
    this.muted = false,
    this.lastChannelId,
    this.lastRefresh,
    this.includeVod = false,
    this.favoriteNumbers = false,
    this.zoom = ZoomMode.fit,
    this.remoteEnabled = false,
    this.remoteCode = '',
    this.remoteTarget = '',
  });

  final bool tvMode;
  final PlaybackProfile profile;
  final Set<String> hiddenGroups;

  /// The first-run "choose your groups" screen was completed or skipped.
  final bool groupsConfigured;

  /// Parental PIN protecting Settings. Empty = no PIN.
  final String pin;
  final double volume;
  final bool muted;
  final String? lastChannelId;
  final DateTime? lastRefresh;

  /// Keep movie/series entries (`/movie/`, `/series/` urls) from the playlist.
  final bool includeVod;

  /// Number keys 1..N pick favorites (in your order) instead of channel numbers.
  final bool favoriteNumbers;
  final ZoomMode zoom;

  /// Windows: accept commands from the phone remote on the local network.
  final bool remoteEnabled;

  /// Pairing code the phone must send.
  final String remoteCode;

  /// Phone: last PC used as remote target, "host|code".
  final String remoteTarget;

  AppSettings copyWith({
    bool? tvMode,
    PlaybackProfile? profile,
    Set<String>? hiddenGroups,
    bool? groupsConfigured,
    String? pin,
    double? volume,
    bool? muted,
    String? lastChannelId,
    DateTime? lastRefresh,
    bool? includeVod,
    bool? favoriteNumbers,
    ZoomMode? zoom,
    bool? remoteEnabled,
    String? remoteCode,
    String? remoteTarget,
  }) =>
      AppSettings(
        tvMode: tvMode ?? this.tvMode,
        profile: profile ?? this.profile,
        hiddenGroups: hiddenGroups ?? this.hiddenGroups,
        groupsConfigured: groupsConfigured ?? this.groupsConfigured,
        pin: pin ?? this.pin,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        lastChannelId: lastChannelId ?? this.lastChannelId,
        lastRefresh: lastRefresh ?? this.lastRefresh,
        includeVod: includeVod ?? this.includeVod,
        favoriteNumbers: favoriteNumbers ?? this.favoriteNumbers,
        zoom: zoom ?? this.zoom,
        remoteEnabled: remoteEnabled ?? this.remoteEnabled,
        remoteCode: remoteCode ?? this.remoteCode,
        remoteTarget: remoteTarget ?? this.remoteTarget,
      );

  Map<String, dynamic> toJson() => {
        'tvMode': tvMode,
        'profile': profile.name,
        'hiddenGroups': hiddenGroups.toList()..sort(),
        'groupsConfigured': groupsConfigured,
        'pin': pin,
        'volume': volume,
        'muted': muted,
        'lastChannelId': lastChannelId,
        'lastRefresh': lastRefresh?.toIso8601String(),
        'includeVod': includeVod,
        'favoriteNumbers': favoriteNumbers,
        'zoom': zoom.name,
        'remoteEnabled': remoteEnabled,
        'remoteCode': remoteCode,
        'remoteTarget': remoteTarget,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return AppSettings(
      tvMode: j['tvMode'] as bool? ?? true,
      profile: byName(PlaybackProfile.values, j['profile'], PlaybackProfile.auto),
      hiddenGroups: {...(j['hiddenGroups'] as List? ?? const []).whereType<String>()},
      groupsConfigured: j['groupsConfigured'] as bool? ?? false,
      pin: j['pin'] as String? ?? '',
      volume: ((j['volume'] as num?) ?? 100).toDouble().clamp(0, 100),
      muted: j['muted'] as bool? ?? false,
      lastChannelId: j['lastChannelId'] as String?,
      lastRefresh: DateTime.tryParse(j['lastRefresh'] as String? ?? ''),
      includeVod: j['includeVod'] as bool? ?? false,
      favoriteNumbers: j['favoriteNumbers'] as bool? ?? false,
      zoom: byName(ZoomMode.values, j['zoom'], ZoomMode.fit),
      remoteEnabled: j['remoteEnabled'] as bool? ?? false,
      remoteCode: j['remoteCode'] as String? ?? '',
      remoteTarget: j['remoteTarget'] as String? ?? '',
    );
  }

  static Future<AppSettings> load(File file) async {
    var settings = const AppSettings();
    try {
      if (await file.exists()) {
        settings = AppSettings.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      }
    } catch (e) {
      AppLog.w('settings.json unreadable, using defaults: $e');
    }
    if (settings.remoteCode.isEmpty) {
      settings = settings.copyWith(remoteCode: '${1000 + Random.secure().nextInt(9000)}');
    }
    return settings;
  }

  /// Atomic write: temp file then rename.
  Future<void> save(File file) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(file.path);
  }
}
