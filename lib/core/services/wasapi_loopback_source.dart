import 'dart:async';

import 'package:flutter/services.dart';

import 'audio_capture_source.dart';

class NativeAudioEventDecoder {
  static AudioPcmChunk decode(Object? event) {
    if (event is! Map) {
      throw const FormatException('Evento audio Windows non valido');
    }
    final rate = event['sampleRateHz'];
    final samples = event['samples'];
    if (rate is! int || rate < 8000 || rate > 384000) {
      throw const FormatException('Frequenza audio Windows non valida');
    }
    if (samples is! List || samples.isEmpty || samples.length > 8192) {
      throw const FormatException('Campioni audio Windows non validi');
    }
    final normalized = samples
        .map((value) {
          if (value is! num || !value.isFinite) {
            throw const FormatException('Campione audio Windows non valido');
          }
          final sample = value.toDouble();
          if (sample < -1.001 || sample > 1.001) {
            throw const FormatException('Campione audio Windows fuori scala');
          }
          return sample.clamp(-1.0, 1.0);
        })
        .toList(growable: false);
    return AudioPcmChunk(normalized, rate);
  }
}

/// Captures the mix played by the default Windows output endpoint through
/// WASAPI loopback. The native runner owns the COM/audio thread; Dart receives
/// normalized mono frames only.
class WasapiLoopbackSource implements AudioCaptureSource {
  WasapiLoopbackSource({MethodChannel? commands, EventChannel? events})
    : _commands = commands ?? const MethodChannel(_commandChannelName),
      _events = events ?? const EventChannel(_eventChannelName);

  static const _commandChannelName = 'lightdome/windows_audio_commands';
  static const _eventChannelName = 'lightdome/windows_audio_frames';

  final MethodChannel _commands;
  final EventChannel _events;
  Stream<AudioPcmChunk>? _frames;

  @override
  String get label => 'Audio riprodotto da Windows';

  @override
  bool get isSupported => true;

  @override
  String get explanation =>
      'Acquisisce in locale ciò che viene riprodotto dall’uscita audio predefinita di Windows.';

  @override
  Stream<AudioPcmChunk> get frames => _frames ??= _events
      .receiveBroadcastStream()
      .map(NativeAudioEventDecoder.decode)
      .asBroadcastStream();

  @override
  Future<void> start() => _commands.invokeMethod<void>('start');

  @override
  Future<void> stop() => _commands.invokeMethod<void>('stop');
}
