import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/services/audio_capture_source.dart';
import 'package:lightdome_app/core/services/audio_feature_processor.dart';

class SimulatedPcmSource implements AudioCaptureSource {
  final controller = StreamController<AudioPcmChunk>.broadcast();
  @override
  String get label => 'Test generator';
  @override
  bool get isSupported => true;
  @override
  String get explanation => 'Only available in tests';
  @override
  Stream<AudioPcmChunk> get frames => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => controller.close();
  void emit(AudioPcmChunk chunk) => controller.add(chunk);
}

AudioPcmChunk sine(double hz, double amplitude) {
  const rate = 16000;
  return AudioPcmChunk(
    List.generate(
      1024,
      (i) => amplitude * math.sin(i * 2 * math.pi * hz / rate),
    ),
    rate,
  );
}

void main() {
  test('bass vs treble energy can be classified without OS audio', () {
    final bass = AudioFeatureProcessor().process(sine(110, .8));
    final treble = AudioFeatureProcessor().process(sine(4400, .8));
    expect(bass.bass, greaterThan(bass.treble));
    expect(treble.treble, greaterThan(treble.bass));
    expect(bass.volume, greaterThan(.4));
    expect(bass.intensity, inInclusiveRange(0, 1));
  });

  test('gate and attack/release shape the final intensity', () {
    final processor = AudioFeatureProcessor(
      tuning: const AudioTuning(
        gate: .1,
        attack: 1,
        release: .5,
        minimum: 0,
        maximum: .8,
      ),
    );
    final initial = processor.process(sine(110, .8));
    final fading = processor.process(sine(110, 0));
    expect(initial.intensity, greaterThan(0));
    expect(fading.intensity, lessThan(initial.intensity));
    expect(fading.intensity, greaterThan(0));
  });

  test('band weights materially change the resulting intensity', () {
    final bassOnly = AudioFeatureProcessor(
      tuning: const AudioTuning(
        attack: 1,
        volumeWeight: 0,
        bassWeight: 1,
        midWeight: 0,
        trebleWeight: 0,
        beatBoost: 0,
      ),
    );
    final trebleOnly = AudioFeatureProcessor(
      tuning: const AudioTuning(
        attack: 1,
        volumeWeight: 0,
        bassWeight: 0,
        midWeight: 0,
        trebleWeight: 1,
        beatBoost: 0,
      ),
    );
    expect(
      bassOnly.process(sine(110, .8)).intensity,
      greaterThan(trebleOnly.process(sine(110, .8)).intensity),
    );
  });

  test('invalid PCM rejected', () {
    final processor = AudioFeatureProcessor();
    expect(
      () => processor.process(const AudioPcmChunk([1, 2], 16000)),
      throwsFormatException,
    );
    expect(
      () =>
          processor.process(AudioPcmChunk(List.filled(128, double.nan), 16000)),
      throwsFormatException,
    );
  });

  test('simulated provider delivers frames for adapters', () async {
    final fake = SimulatedPcmSource();
    final nextFrame = fake.frames.first;
    fake.emit(sine(110, .5));
    final frame = await nextFrame;
    expect(frame.sampleRateHz, 16000);
    await fake.stop();
  });

  test('system provider explicitly refuses capture', () async {
    const source = UnavailableSystemAudioSource();
    expect(source.isSupported, isFalse);
    await expectLater(source.start(), throwsUnsupportedError);
  });
}
