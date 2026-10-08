import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/services/android_playback_audio_source.dart';

class FakeAndroidBridge implements AndroidAudioPlatformBridge {
  final controller = StreamController<dynamic>.broadcast();
  int starts = 0;
  int stops = 0;

  @override
  Stream<dynamic> get events => controller.stream;

  @override
  Future<Map<Object?, Object?>> checkAvailability() async => {
    'supported': true,
    'sdk': 35,
  };

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('PCM16 mono little-endian is normalized without retaining bytes', () {
    final chunk = decodePcm16Mono(
      Uint8List.fromList([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]),
      48000,
    );
    expect(chunk.sampleRateHz, 48000);
    expect(chunk.samples[0], -1.0);
    expect(chunk.samples[1], 0.0);
    expect(chunk.samples[2], closeTo(32767 / 32768, 1e-9));
  });

  test('PCM decoder rejects malformed chunks and sample rates', () {
    expect(
      () => decodePcm16Mono(Uint8List.fromList([1]), 48000),
      throwsFormatException,
    );
    expect(
      () => decodePcm16Mono(Uint8List.fromList([0, 0]), 1000),
      throwsFormatException,
    );
  });

  test('Android source starts, emits validated frames and stops', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bridge = FakeAndroidBridge();
    final source = AndroidPlaybackAudioSource(bridge: bridge);

    final availability = await source.checkAvailability();
    expect(availability.supported, isTrue);
    expect(availability.sdk, 35);

    await source.start();
    expect(bridge.starts, 1);
    final frame = source.frames.first;
    bridge.controller.add({
      'type': 'pcm16',
      'sampleRateHz': 48000,
      'channels': 1,
      'data': Uint8List.fromList([0, 0, 0xff, 0x7f]),
    });
    expect((await frame).samples.length, 2);

    await source.stop();
    expect(bridge.stops, 1);
    await source.dispose();
    await bridge.controller.close();
  });

  test('non-Android platforms are explicitly unsupported', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final source = AndroidPlaybackAudioSource(bridge: FakeAndroidBridge());
    expect(source.isSupported, isFalse);
    expect(source.explanation, contains('Android 10'));
  });

  test(
    'initial stopped status is harmless, revocation after running is an error',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final bridge = FakeAndroidBridge();
      final source = AndroidPlaybackAudioSource(bridge: bridge);
      final errors = <Object>[];
      final subscription = source.frames.listen(
        (_) {},
        onError: (Object error) => errors.add(error),
      );

      await source.start();
      bridge.controller.add({
        'type': 'status',
        'status': 'stopped',
        'message': 'Audio non attivo',
      });
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);

      bridge.controller.add({
        'type': 'status',
        'status': 'running',
        'message': 'Audio attivo',
      });
      bridge.controller.add({
        'type': 'status',
        'status': 'stopped',
        'message': 'Consenso revocato',
      });
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));

      await source.stop();
      await subscription.cancel();
      await source.dispose();
      await bridge.controller.close();
    },
  );

  test(
    'event channel loss becomes an audio error after capture starts',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final bridge = FakeAndroidBridge();
      final source = AndroidPlaybackAudioSource(bridge: bridge);
      final error = Completer<Object>();
      final subscription = source.frames.listen(
        (_) {},
        onError: (Object value) => error.complete(value),
      );

      await source.start();
      bridge.controller.add({
        'type': 'status',
        'status': 'running',
        'message': 'Audio attivo',
      });
      await Future<void>.delayed(Duration.zero);
      await bridge.controller.close();

      expect(await error.future, isA<StateError>());
      await source.stop();
      await subscription.cancel();
      await source.dispose();
    },
  );

  test('availability attaches to an already-running native session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bridge = FakeAndroidBridge();
    final source = AndroidPlaybackAudioSource(bridge: bridge);

    await source.checkAvailability();
    bridge.controller.add({
      'type': 'status',
      'status': 'running',
      'message': 'Audio ancora attivo',
    });
    await Future<void>.delayed(Duration.zero);
    expect(source.state.status, AndroidAudioStatus.running);

    await source.start();
    expect(bridge.starts, 1);
    expect(source.state.status, AndroidAudioStatus.running);

    await source.stop();
    await source.dispose();
    await bridge.controller.close();
  });
}
