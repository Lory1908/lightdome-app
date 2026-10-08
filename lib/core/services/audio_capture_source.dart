import 'dart:async';

/// Audio capture is always opt-in. Implementations must never save PCM or
/// report simulated samples as real playback audio.
abstract class AudioCaptureSource {
  String get label;
  bool get isSupported;
  String get explanation;
  Stream<AudioPcmChunk> get frames;
  Future<void> start();
  Future<void> stop();
}

class AudioPcmChunk {
  const AudioPcmChunk(this.samples, this.sampleRateHz);
  final List<double> samples; // signed, mono and normalized to -1..1
  final int sampleRateHz;
}

class UnavailableSystemAudioSource implements AudioCaptureSource {
  const UnavailableSystemAudioSource();

  @override
  String get label => 'Audio del telefono';
  @override
  bool get isSupported => false;
  @override
  String get explanation =>
      'Disponibile soltanto nell’app Android 10 o successiva. Web, iPhone e desktop non acquisiscono l’audio.';
  @override
  Stream<AudioPcmChunk> get frames => const Stream.empty();
  @override
  Future<void> start() async => throw UnsupportedError(explanation);
  @override
  Future<void> stop() async {}
}
