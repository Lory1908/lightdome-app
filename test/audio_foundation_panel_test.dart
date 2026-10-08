import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/pages/tabs/audio_foundation_panel.dart';

void main() {
  testWidgets('desktop UI clearly says phone audio is unavailable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AudioFoundationPanel())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Audio del telefono'), findsOneWidget);
    expect(
      find.textContaining('Disponibile soltanto nell’app Android'),
      findsWidgets,
    );
    expect(find.textContaining('Avvia audio del telefono'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
