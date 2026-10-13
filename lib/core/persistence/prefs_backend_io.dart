import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class PrefsBackend {
  late final File _file;
  Map<String, dynamic> _cache = {};

  Future<void> init() async {
    final legacyFile = File(_prefsFilePath());
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      _file = File(
        '${support.path}${Platform.pathSeparator}lightdome-prefs.json',
      );
      if (!await _file.exists() &&
          legacyFile.path != _file.path &&
          await legacyFile.exists()) {
        await _file.parent.create(recursive: true);
        await legacyFile.copy(_file.path);
      }
    } else {
      _file = legacyFile;
    }
    try {
      if (await _file.exists()) {
        final txt = await _file.readAsString();
        _cache = (jsonDecode(txt) as Map).cast<String, dynamic>();
      } else {
        await _file.parent.create(recursive: true);
        await _file.writeAsString('{}');
        _cache = {};
      }
    } catch (_) {
      _cache = {};
    }
  }

  Future<String?> getString(String key) async {
    final v = _cache[key];
    return v is String ? v : null;
  }

  Future<void> setString(String key, String value) async {
    _cache[key] = value;
    await _flush();
  }

  Future<void> remove(String key) async {
    _cache.remove(key);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _file.writeAsString(jsonEncode(_cache));
    } catch (_) {
      // ignore write errors silently
    }
  }

  String _prefsFilePath() {
    final sep = Platform.pathSeparator;
    String base;
    final home = Platform.environment['HOME'];
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? home ?? Directory.systemTemp.path;
      base = '$appData${sep}LightDome';
    } else if (Platform.isLinux) {
      final cfg =
          Platform.environment['XDG_CONFIG_HOME'] ??
          (home != null ? '$home$sep.config' : Directory.systemTemp.path);
      base = '$cfg${sep}lightdome';
    } else if (Platform.isMacOS || Platform.isIOS) {
      final h = home ?? Directory.systemTemp.path;
      base = '$h${sep}Library${sep}Application Support${sep}LightDome';
    } else if (Platform.isAndroid) {
      // HOME may exist on Android; otherwise fall back to cache dir.
      final root = home ?? Directory.systemTemp.path;
      base = '$root${sep}LightDome';
    } else {
      final root = home ?? Directory.systemTemp.path;
      base = '$root${sep}LightDome';
    }
    return '$base${sep}prefs.json';
  }
}
