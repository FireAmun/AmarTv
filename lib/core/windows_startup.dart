import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

/// "Start with Windows": a shortcut in the user's Startup folder.
/// No registry, no admin rights. Only created when the user turns it on.
class WindowsStartup {
  WindowsStartup._();

  static File? get _shortcut {
    final appData = Platform.environment['APPDATA'];
    if (!Platform.isWindows || appData == null) return null;
    return File(p.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'AmarTv.lnk'));
  }

  static bool get isEnabled => _shortcut?.existsSync() ?? false;

  static Future<bool> setEnabled(bool enabled) async {
    final lnk = _shortcut;
    if (lnk == null) return false;
    try {
      if (!enabled) {
        if (await lnk.exists()) await lnk.delete();
        return true;
      }
      final exe = Platform.resolvedExecutable;
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final script = r'$s=(New-Object -ComObject WScript.Shell).CreateShortcut(' '${q(lnk.path)});'
          r'$s.TargetPath=' '${q(exe)};'
          r'$s.WorkingDirectory=' '${q(File(exe).parent.path)};'
          r'$s.Save()';
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
      if (r.exitCode != 0) {
        AppLog.w('Creating startup shortcut failed: ${r.stderr}');
        return false;
      }
      return lnk.exists();
    } catch (e) {
      AppLog.w('Startup shortcut error: $e');
      return false;
    }
  }
}
