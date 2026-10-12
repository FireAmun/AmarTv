import 'dart:convert';
import 'dart:io';

import 'log.dart';
import 'url_mask.dart';

/// Contents of `config.json` (editable in Notepad).
class AppConfig {
  const AppConfig({required this.playlistUrl, this.userAgent = ''});

  static const placeholderUrl =
      'http://example.com/get.php?username=USER&password=PASS&type=m3u&output=ts';

  /// Set only in personal builds (`--dart-define=AMARTV_URL=...`, see
  /// scripts/build_personal.ps1) so a phone needs no setup. Never in git.
  static const embeddedUrl = String.fromEnvironment('AMARTV_URL');

  final String playlistUrl;

  /// Optional HTTP User-Agent for the playlist and streams. Some providers
  /// only answer known players. Empty = library default.
  final String userAgent;

  bool get isConfigured {
    final uri = Uri.tryParse(playlistUrl.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.host != 'example.com';
  }

  Map<String, dynamic> toJson() => {'playlistUrl': playlistUrl, 'userAgent': userAgent};

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        playlistUrl: (json['playlistUrl'] as String? ?? '').trim(),
        userAgent: (json['userAgent'] as String? ?? '').trim(),
      );

  /// Reads [file]; creates it from [example] (or the built-in placeholder)
  /// when missing. Returns the config and whether the file was just created.
  static Future<(AppConfig, bool)> load(File file, File? example) async {
    var created = false;
    if (!await file.exists()) {
      created = true;
      try {
        if (embeddedUrl.isNotEmpty) {
          // Personal build: the URL was baked in with --dart-define.
          await _write(file, const AppConfig(playlistUrl: embeddedUrl));
          created = false;
        } else if (example != null && await example.exists()) {
          await example.copy(file.path);
        } else {
          await _write(file, const AppConfig(playlistUrl: placeholderUrl));
        }
      } catch (e) {
        AppLog.w('Could not create ${file.path}: $e');
        return (const AppConfig(playlistUrl: placeholderUrl), created);
      }
    }
    try {
      final json = jsonDecode(await file.readAsString());
      final config = AppConfig.fromJson(json as Map<String, dynamic>);
      UrlMasker.addSecretsFromUrl(config.playlistUrl);
      return (config, created);
    } catch (e) {
      AppLog.w('config.json is not valid JSON: $e');
      return (const AppConfig(playlistUrl: ''), created);
    }
  }

  static Future<void> save(File file, AppConfig config) async {
    UrlMasker.addSecretsFromUrl(config.playlistUrl);
    await _write(file, config);
  }

  static Future<void> _write(File file, AppConfig config) async {
    const encoder = JsonEncoder.withIndent('  ');
    await file.parent.create(recursive: true);
    await file.writeAsString('${encoder.convert(config.toJson())}\n', flush: true);
  }
}
