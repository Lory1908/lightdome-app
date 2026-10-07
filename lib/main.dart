import 'package:flutter/material.dart';

import 'pages/home_scaffold.dart';
import 'core/persistence/prefs.dart';
import 'controllers/device_controller.dart';
import 'core/services/app_settings.dart';
import 'core/services/device_directory.dart';
import 'core/theme/lightdome_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.init();
  await AppSettings.I.restore();
  await DeviceDirectory.I.restore();
  await DeviceController.I.restoreLastDevice();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettings.I,
      builder: (context, _) => MaterialApp(
        title: 'LightDome',
        debugShowCheckedModeBanner: false,
        theme: LightDomeTheme.light(),
        darkTheme: LightDomeTheme.dark(),
        themeMode: switch (AppSettings.I.themePreference) {
          AppThemePreference.system => ThemeMode.system,
          AppThemePreference.light => ThemeMode.light,
          AppThemePreference.dark => ThemeMode.dark,
        },
        home: const HomeScaffold(),
      ),
    );
  }
}
