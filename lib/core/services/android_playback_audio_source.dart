import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_capture_source.dart';

enum AndroidAudioStatus { stopped, starting, running, error }

class AndroidAudioState {
  const AndroidAudioState(this.status, this.message);

  final AndroidAudioStatus status;
  final String message;
}

class AndroidAudioAvailability {
  const AndroidAudioAvailability({required this.supported, required this.sdk});

  final bool supported;
  final int sdk;
}

abstract class AndroidAudioPlatformBridge {
  Stream<dynamic> get events;
  Future<Map<Object?, Object?>> checkAvailability();
  Future<void> start();
  Future<void> stop();
}

class MethodChannelAndroidAudioBridge implements AndroidAudioPlatformBridge {
  const MethodChannelAndroidAudioBridge();

  static const _methods = MethodChannel('lightdome/audio_playback_capture');
  static const _events = EventChannel(
    'lightdome/audio_playback_capture/events',
  );

  @override
  Stream<dynamic> get events => _events.receiveBroadcastStream();

  @override
  Future<Map<Object?, Object?>> checkAvailability() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'availability',
    );
    return result ?? const {};
  }

  @override
  Future<void> start() => _methods.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');
}

/// Android 10+ playback capture. Android sends transient PCM16 chunks; this
/// class validates and normalizes them to -1..1 before exposing them to the
/// shared feature processor. Samples are never persisted.
class AndroidPlaybackAudioSource implements AudioCaptureSource {
  AndroidPlaybackAudioSource({
    AndroidAudioPlatformBridge bridge = const MethodChannelAndroidAudioBridge(),
  }) : _bridge = bridge;

  final AndroidAudioPlatformBridge _bridge;
  final _frames = StreamController<AudioPcmChunk>.broadcast(sync: true);
  final _states = StreamController<AndroidAudioState>.broadcast(sync: true);
  StreamSubscription<dynamic>? _eventsSubscription;
  bool _intentionalStop = false;
  AndroidAudioState _state = const AndroidAudioState(
    AndroidAudioStatus.stopped,
    'Audio non attivo',
  );

  AndroidAudioState get state => _state;
  Stream<AndroidAudioState> get states => _states.stream;

  @override
  String get label => 'Audio del telefono';

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  String get explanation => isSupported
      ? 'Richiede Android 10 o successivo e una conferma a ogni sessione. Alcune app e i contenuti protetti possono impedire la cattura.'
      : 'Audio della riproduzione disponibile soltanto nell’app Android 10 o successiva.';

  @override
  Stream<AudioPcmChunk> get frames => _frames.stream;

  Future<AndroidAudioAvailability> checkAvailability() async {
    if (!isSupported) {
      return const AndroidAudioAvailability(supported: false, sdk: 0);
    }
    _ensureListening();
    final result = await _bridge.checkAvailability();
    return AndroidAudioAvailability(
      supported: result['supported'] == true,
      sdk: (result['sdk'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> start() async {
    if (!isSupported) throw UnsupportedError(explanation);
    _intentionalStop = false;
    _ensureListening();
    if (_state.status != AndroidAudioStatus.running) {
      _setState(AndroidAudioStatus.starting, 'In attesa del consenso Android…');
    }
    try {
      await _bridge.start();
    } catch (error) {
      _setState(AndroidAudioStatus.error, _platformMessage(error));
      await _eventsSubscription?.cancel();
      _eventsSubscription = null;
      rethrow;
    }
  }

  void _ensureListening() {
    if (_eventsSubscription != null) return;
    _eventsSubscription = _bridge.events.listen(
      _handleEvent,
      onError: (Object error, StackTrace stackTrace) {
        _setState(AndroidAudioStatus.error, _platformMessage(error));
        _frames.addError(error, stackTrace);
      },
      onDone: () {
        _eventsSubscription = null;
        if (_state.status == AndroidAudioStatus.running) {
          _setState(
            AndroidAudioStatus.error,
            'La cattura audio è stata interrotta dal sistema.',
          );
          _frames.addError(StateError(_state.message));
        }
      },
    );
  }

  @override
  Future<void> stop() async {
    _intentionalStop = true;
    try {
      await _bridge.stop();
    } finally {
      await _eventsSubscription?.cancel();
      _eventsSubscription = null;
      _setState(AndroidAudioStatus.stopped, 'Audio fermato');
    }
  }

  Future<void> dispose() async {
    await _eventsSubscription?.cancel();
    await _frames.close();
    await _states.close();
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    if (type == 'status') {
      final previousStatus = _state.status;
      final raw = event['status']?.toString();
      final status = switch (raw) {
        'starting' => AndroidAudioStatus.starting,
        'running' => AndroidAudioStatus.running,
        'error' => AndroidAudioStatus.error,
        _ => AndroidAudioStatus.stopped,
      };
      _setState(status, event['message']?.toString() ?? '');
      if (status == AndroidAudioStatus.error) {
        _frames.addError(StateError(_state.message));
      } else if (status == AndroidAudioStatus.stopped &&
          previousStatus == AndroidAudioStatus.running &&
          !_intentionalStop) {
        _frames.addError(StateError(_state.message));
      }
      return;
    }
    if (type != 'pcm16') return;
    final sampleRate = (event['sampleRateHz'] as num?)?.toInt() ?? 0;
    final channels = (event['channels'] as num?)?.toInt() ?? 0;
    final data = event['data'];
    if (data is! Uint8List || channels != 1) {
      _frames.addError(
        const FormatException('Formato audio Android non valido'),
      );
      return;
    }
    try {
      _frames.add(decodePcm16Mono(data, sampleRate));
    } catch (error, stackTrace) {
      _frames.addError(error, stackTrace);
    }
  }

  void _setState(AndroidAudioStatus status, String message) {
    _state = AndroidAudioState(status, message);
    if (!_states.isClosed) _states.add(_state);
  }

  String _platformMessage(Object error) {
    if (error is PlatformException) return error.message ?? error.code;
    return error.toString();
  }
}

AudioPcmChunk decodePcm16Mono(Uint8List bytes, int sampleRateHz) {
  if (sampleRateHz < 8000 || sampleRateHz > 192000) {
    throw const FormatException('Frequenza PCM non valida');
  }
  if (bytes.isEmpty || bytes.length.isOdd || bytes.length > 16384) {
    throw const FormatException('Dimensione PCM non valida');
  }
  final view = ByteData.sublistView(bytes);
  final samples = List<double>.generate(
    bytes.length ~/ 2,
    (index) => view.getInt16(index * 2, Endian.little) / 32768.0,
    growable: false,
  );
  return AudioPcmChunk(samples, sampleRateHz);
}
