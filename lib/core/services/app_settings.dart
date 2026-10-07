import 'package:flutter/foundation.dart';

import '../persistence/prefs.dart';

enum AppThemePreference { system, light, dark }

class AppSettings extends ChangeNotifier {
  static final AppSettings I = AppSettings._();
  AppSettings._();

  bool showPreview = true;
  bool showDescriptions = true;
  AppThemePreference themePreference = AppThemePreference.system;

  Future<void> restore() async {
    showPreview = (await Prefs.getString('ui_show_preview')) != '0';
    showDescriptions = (await Prefs.getString('ui_show_desc')) != '0';
    final savedTheme = await Prefs.getString('ui_theme');
    themePreference = AppThemePreference.values.firstWhere(
      (value) => value.name == savedTheme,
      orElse: () => AppThemePreference.system,
    );
    notifyListeners();
  }

  Future<void> setShowPreview(bool v) async {
    showPreview = v;
    await Prefs.setString('ui_show_preview', v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setShowDescriptions(bool v) async {
    showDescriptions = v;
    await Prefs.setString('ui_show_desc', v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setThemePreference(AppThemePreference value) async {
    themePreference = value;
    await Prefs.setString('ui_theme', value.name);
    notifyListeners();
  }
}
