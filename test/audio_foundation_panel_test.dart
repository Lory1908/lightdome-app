import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/controllers/device_controller.dart';
import 'package:lightdome_app/core/models/device_state.dart';
import 'package:lightdome_app/core/services/audio_capture_source.dart';
import 'package:lightdome_app/pages/tabs/audio_foundation_panel.dart';

class _SupportedSource implements AudioCaptureSource {
  const _SupportedSource();

  @override
  String get label => 'Test Windows audio';

  @override
  bool get isSupported => true;

  @override
  String get explanation => 'Test source';

  @override
  Stream<AudioPcmChunk> get frames => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('audio button follows DeviceController connection changes', (
    tester,
  ) async {
    final controller = DeviceController.I;
    final previous = controller.state;
    addTearDown(() {
      controller.state = previous;
      controller.notifyListeners();
    });
    controller.state = DeviceState.initial();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AudioFoundationPanel(source: _SupportedSource()),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Audio del computer'));
    await tester.pumpAndSettle();

    FilledButton button() => tester.widget<FilledButton>(
      find.byKey(const Key('system-audio-toggle')),
    );
    expect(button().onPressed, isNull);

    controller.state = controller.state.copyWith(connected: true);
    controller.notifyListeners();
    await tester.pump();

    expect(button().onPressed, isNotNull);
  });
}
