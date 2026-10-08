import 'dart:async';

import 'audio_capture_source.dart';
import 'audio_feature_processor.dart';

/// Transport-agnostic audio session. A future WASAPI adapter can use
/// DeviceApi.sendAudioY, configureAudioFallback and stopAudio directly.
class AudioStreamCoordinator {
  AudioStreamCoordinator({
    required this.source,
    required this.processor,
    required this.sendLevel,
    required this.onAudioLost,
    this.onFeatures,
  });

  final AudioCaptureSource source;
  final AudioFeatureProcessor processor;
  final Future<void> Function(double level) sendLevel;
  final Future<void> Function() onAudioLost;
  final void Function(AudioFeatures)? onFeatures;
  StreamSubscription<AudioPcmChunk>? _subscription;
  bool _running = false;
  bool _lost = false;

  bool get running => _running;

  Future<void> start() async {
    if (_running) return;
    if (!source.isSupported) throw UnsupportedError(source.explanation);
    _lost = false;
    processor.reset();
    _subscription = source.frames.listen(
      (chunk) {
        if (!_running) return;
        try {
          final frame = processor.process(chunk);
          onFeatures?.call(frame);
          // The provider should coalesce packets/serialize sends if necessary.
          unawaited(
            sendLevel(frame.intensity).catchError((Object _) => _lose()),
          );
        } catch (_) {
          unawaited(_lose());
        }
      },
      onDone: () => unawaited(_lose()),
      onError: (Object error, StackTrace stackTrace) => unawaited(_lose()),
    );
    _running = true;
    try {
      await source.start();
    } catch (_) {
      await _lose();
      rethrow;
    }
  }

  Future<void> stop() => _lose();

  Future<void> _lose() async {
    if (_lost) return;
    _lost = true;
    _running = false;
    final sub = _subscription;
    _subscription = null;
    await sub?.cancel();
    try {
      await source.stop();
    } finally {
      await onAudioLost();
    }
  }
}
