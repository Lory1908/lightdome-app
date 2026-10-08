import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/services/audio_capture_source.dart';
import 'package:lightdome_app/core/services/audio_feature_processor.dart';
import 'package:lightdome_app/core/services/audio_stream_coordinator.dart';

class TestCapture implements AudioCaptureSource {
  TestCapture({this.stopThrows = false});

  final controller = StreamController<AudioPcmChunk>();
  final bool stopThrows;
  bool started = false;
  @override
  String get label => 'test';
  @override
  bool get isSupported => true;
  @override
  String get explanation => '';
  @override
  Stream<AudioPcmChunk> get frames => controller.stream;
  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
    if (stopThrows) throw StateError('platform detached');
    await controller.close();
  }
}

void main() {
  test('stream forwards intensity and stops safely on source end', () async {
    final fake = TestCapture();
    final levels = <double>[];
    var lost = 0;
    var stopped = 0;
    final session = AudioStreamCoordinator(
      source: fake,
      processor: AudioFeatureProcessor(),
      sendLevel: (level) async {
        levels.add(level);
      },
      onAudioLost: () async {
        lost++;
      },
      onStopped: () => stopped++,
    );
    await session.start();
    fake.controller.add(
      AudioPcmChunk(
        List.generate(512, (i) => math.sin(2 * math.pi * 100 * i / 16000)),
        16000,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(levels, isNotEmpty);
    await fake.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(session.running, isFalse);
    expect(lost, 1);
    expect(stopped, 1);
    await session.stop();
    expect(lost, 1);
    expect(stopped, 1);
  });

  test('rapid frames are coalesced and network sends never overlap', () async {
    final fake = TestCapture();
    var activeSends = 0;
    var maxActiveSends = 0;
    var totalSends = 0;
    final session = AudioStreamCoordinator(
      source: fake,
      processor: AudioFeatureProcessor(),
      sendLevel: (level) async {
        activeSends++;
        totalSends++;
        maxActiveSends = math.max(maxActiveSends, activeSends);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        activeSends--;
      },
      onAudioLost: () async {},
    );
    await session.start();
    for (var i = 0; i < 10; i++) {
      fake.controller.add(
        AudioPcmChunk(
          List.generate(
            512,
            (sample) => math.sin(2 * math.pi * (100 + i) * sample / 16000),
          ),
          16000,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(maxActiveSends, 1);
    expect(totalSends, lessThan(10));
    await session.stop();
  });

  test('cleanup completes once when platform stop throws', () async {
    final fake = TestCapture(stopThrows: true);
    var lost = 0;
    var stopped = 0;
    final session = AudioStreamCoordinator(
      source: fake,
      processor: AudioFeatureProcessor(),
      sendLevel: (_) async {},
      onAudioLost: () async => lost++,
      onStopped: () => stopped++,
    );

    await session.start();
    await session.stop();

    expect(session.running, isFalse);
    expect(lost, 1);
    expect(stopped, 1);
    await fake.controller.close();
  });
}
