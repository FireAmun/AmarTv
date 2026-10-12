/// Hides credentials in URLs and free text (logs, error messages).
///
/// Handles the common IPTV forms:
///   http://host/get.php?username=U&password=P&type=m3u
///   http://host:8080/live/U/P/123.ts   and   http://host/U/P/123
///   http://U:P@host/stream
/// plus any literal secret registered with [UrlMasker.addSecrets].
class UrlMasker {
  UrlMasker._();

  static const mask = '***';
  static final Set<String> _secrets = {};

  static final _queryParam = RegExp(
    r'((?:^|[?&;\s])(?:username|user|password|pass|pwd|token|key)=)([^&\s#"]+)',
    caseSensitive: false,
  );
  static final _userInfo = RegExp(r'(https?://)([^/@\s:]+):([^/@\s]+)@');
  static final _xtreamPath = RegExp(
    r'(https?://[^/\s]+/(?:live/|movie/|series/|timeshift/)?)([^/\s?]+)/([^/\s?]+)/(\d+(?:\.[a-z0-9]{2,4})?)(?=$|[\s?"#])',
    caseSensitive: false,
  );

  /// Registers secrets (e.g. username/password from the configured playlist
  /// URL) so they are also hidden wherever they appear verbatim.
  static void addSecretsFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;
    for (final entry in uri.queryParameters.entries) {
      const keys = {'username', 'user', 'password', 'pass', 'pwd', 'token'};
      if (keys.contains(entry.key.toLowerCase())) addSecrets([entry.value]);
    }
    if (uri.userInfo.isNotEmpty) addSecrets(uri.userInfo.split(':'));
  }

  static void addSecrets(Iterable<String> values) {
    for (final v in values) {
      // Very short values would mask unrelated text; skip them.
      if (v.length >= 3) _secrets.add(v);
    }
  }

  static void clearSecrets() => _secrets.clear();

  /// Pattern-based masking only (no registered secrets) - deterministic,
  /// safe to use in isolates and for hashing.
  static String maskPatterns(String text) => text
      .replaceAllMapped(_queryParam, (m) => '${m[1]}$mask')
      .replaceAllMapped(_userInfo, (m) => '${m[1]}$mask:$mask@')
      .replaceAllMapped(_xtreamPath, (m) => '${m[1]}$mask/$mask/${m[4]}');

  static String maskText(String text) {
    var out = maskPatterns(text);
    for (final s in _secrets) {
      out = out.replaceAll(s, mask);
      final encoded = Uri.encodeQueryComponent(s);
      if (encoded != s) out = out.replaceAll(encoded, mask);
    }
    return out;
  }
}

String maskUrl(String text) => UrlMasker.maskText(text);
