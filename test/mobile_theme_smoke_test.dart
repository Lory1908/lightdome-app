import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/services/app_settings.dart';
import 'package:lightdome_app/main.dart';

void main() {
  for (final width in <double>[390, 320]) {
    for (final theme in <AppThemePreference>[
      AppThemePreference.light,
      AppThemePreference.dark,
    ]) {
      testWidgets('Home is usable at ${width.toInt()}px, ${theme.name}', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        AppSettings.I.themePreference = theme;
        await tester.pumpWidget(const MyApp());
        await tester.pump();
        expect(find.text('LightDome'), findsOneWidget);
        expect(find.text('Home'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
