import 'dart:async';

import 'audio_capture_source.dart';
import 'audio_feature_processor.dart';

/// Transport-agnostic audio session. Android playback capture supplies PCM;
/// this coordinator coalesces the resulting levels so HTTP writes never overlap.
class AudioStreamCoordinator {
  AudioStreamCoordinator({
    required this.source,
    required this.processor,
    required this.sendLevel,
    required this.onAudioLost,
    this.onFeatures,
    this.onStopped,
    this.minimumSendInterval = const Duration(milliseconds: 70),
    this.networkRetryDelay = const Duration(milliseconds: 300),
  });

  final AudioCaptureSource source;
  final AudioFeatureProcessor processor;
  final Future<void> Function(double level) sendLevel;
  final Future<void> Function() onAudioLost;
  final void Function(AudioFeatures)? onFeatures;
  final FutureOr<void> Function()? onStopped;
  final Duration minimumSendInterval;
  final Duration networkRetryDelay;
  StreamSubscription<AudioPcmChunk>? _subscription;
  bool _running = false;
  bool _lost = false;
  bool _sending = false;
  double? _pendingLevel;
  final Stopwatch _sendClock = Stopwatch();
  int? _lastSendMicroseconds;

  bool get running => _running;

  Future<void> start() async {
    if (_running) return;
    if (!source.isSupported) throw UnsupportedError(source.explanation);
    _lost = false;
    processor.reset();
    _sendClock
      ..reset()
      ..start();
    _lastSendMicroseconds = null;
    _subscription = source.frames.listen(
      (chunk) {
        if (!_running) return;
        try {
          final frame = processor.process(chunk);
          onFeatures?.call(frame);
          // Keep only the newest unsent level and never overlap HTTP writes.
          _pendingLevel = frame.intensity;
          unawaited(_drainLevels());
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

  Future<void> _drainLevels() async {
    if (_sending || !_running) return;
    _sending = true;
    try {
      while (_running && _pendingLevel != null) {
        final lastSent = _lastSendMicroseconds;
        if (lastSent != null) {
          final elapsed = _sendClock.elapsedMicroseconds - lastSent;
          final remaining = minimumSendInterval.inMicroseconds - elapsed;
          if (remaining > 0) {
            await Future<void>.delayed(Duration(microseconds: remaining));
          }
          if (!_running) break;
        }
        final level = _pendingLevel!;
        _pendingLevel = null;
        await sendLevel(level);
        _lastSendMicroseconds = _sendClock.elapsedMicroseconds;
      }
    } catch (_) {
      // A temporary Wi-Fi outage must not revoke MediaProjection. Keep the
      // capture session alive, let the firmware watchdog fade safely, and
      // retry only the newest level at a modest cadence until the LAN returns.
      if (_running) await Future<void>.delayed(networkRetryDelay);
    } finally {
      _sending = false;
      if (_running && _pendingLevel != null) unawaited(_drainLevels());
    }
  }

  Future<void> _lose() async {
    if (_lost) return;
    _lost = true;
    _running = false;
    _pendingLevel = null;
    _sendClock.stop();
    final sub = _subscription;
    _subscription = null;
    await sub?.cancel();
    try {
      await source.stop();
    } catch (_) {
      // The platform/event channel may already be detached. Cleanup and the
      // firmware watchdog must still complete deterministically.
    } finally {
      await onAudioLost();
      await onStopped?.call();
    }
  }
}
