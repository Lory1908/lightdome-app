import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../controllers/device_controller.dart';
import 'android_playback_audio_source.dart';
import 'audio_feature_processor.dart';
import 'audio_stream_coordinator.dart';

/// Long-lived Dart side of the Android playback session. It is independent
/// from the current tab, so switching screen or backgrounding the Activity
/// does not intentionally stop capture.
class AndroidAudioSession extends ChangeNotifier {
  AndroidAudioSession._({AndroidPlaybackAudioSource? source})
    : source = source ?? AndroidPlaybackAudioSource() {
    _sourceStates = this.source.states.listen((next) {
      state = next;
      notifyListeners();
    });
  }

  static final AndroidAudioSession I = AndroidAudioSession._();

  final AndroidPlaybackAudioSource source;
  final AudioFeatureProcessor processor = AudioFeatureProcessor();
  late final StreamSubscription<AndroidAudioState> _sourceStates;
  AudioStreamCoordinator? _coordinator;

  AndroidAudioState state = const AndroidAudioState(
    AndroidAudioStatus.stopped,
    'Audio non attivo',
  );
  AudioFeatures? features;
  AndroidAudioAvailability? availability;
  bool checkingAvailability = false;

  bool get running => _coordinator?.running == true;
  bool get platformCandidate => source.isSupported;

  Future<void> refreshAvailability() async {
    if (!source.isSupported) {
      availability = const AndroidAudioAvailability(supported: false, sdk: 0);
      notifyListeners();
      return;
    }
    checkingAvailability = true;
    notifyListeners();
    try {
      availability = await source.checkAvailability();
    } catch (_) {
      availability = const AndroidAudioAvailability(supported: false, sdk: 0);
    } finally {
      checkingAvailability = false;
      notifyListeners();
    }
  }

  void updateTuning(AudioTuning tuning) {
    processor.tuning = tuning;
  }

  Future<void> start() async {
    if (_coordinator?.running == true) return;
    if (!DeviceController.I.isConnected) {
      throw StateError('Connetti prima la cupola.');
    }
    await refreshAvailability();
    if (availability?.supported != true) {
      throw UnsupportedError(
        'Audio del telefono richiede Android 10 o successivo.',
      );
    }
    final coordinator = AudioStreamCoordinator(
      source: source,
      processor: processor,
      sendLevel: DeviceController.I.sendAudioLevel,
      // On unexpected capture loss the firmware watchdog performs the chosen
      // fade/fallback. Sending an explicit stop here would disarm it.
      onAudioLost: () async {},
      onFeatures: (next) {
        features = next;
        notifyListeners();
      },
    );
    _coordinator = coordinator;
    try {
      await coordinator.start();
    } catch (_) {
      _coordinator = null;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final coordinator = _coordinator;
    _coordinator = null;
    await coordinator?.stop();
    features = null;
    await DeviceController.I.stopAudioStream();
    notifyListeners();
  }

  @visibleForTesting
  Future<void> disposeSession() async {
    await _sourceStates.cancel();
    await source.dispose();
    dispose();
  }
}
