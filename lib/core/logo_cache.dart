import 'dart:io' as io;

import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

/// Bounded channel-logo cache stored in `data/amartv/logos` so it travels
/// with the portable folder.
class LogoCache {
  LogoCache._();

  static const _key = 'amartv_logos';
  static CacheManager? _instance;

  static CacheManager get manager => _instance ??= CacheManager(Config(_key));

  static void init(io.Directory dir) {
    _instance = CacheManager(Config(
      _key,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 1500,
      repo: JsonCacheInfoRepository.withFile(io.File(p.join(dir.path, 'index.json'))),
      fileSystem: _DirFileSystem(dir.path),
    ));
  }

  static Future<void> clear() async => manager.emptyCache();
}

class _DirFileSystem implements FileSystem {
  _DirFileSystem(this.path);
  final String path;

  @override
  Future<File> createFile(String name) async {
    final dir = const LocalFileSystem().directory(p.join(path, 'files'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.childFile(name);
  }
}
