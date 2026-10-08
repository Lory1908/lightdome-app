import 'dart:async';

/// Audio capture is opt-in. The Windows WASAPI loopback adapter is not yet
/// supplied: never report simulated samples as real system sound.
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
  String get label => 'Audio del computer';
  @override
  bool get isSupported => false;
  @override
  String get explanation =>
      'Cattura del sistema non ancora disponibile. Su Windows serve un provider WASAPI loopback; nessuna registrazione è in corso.';
  @override
  Stream<AudioPcmChunk> get frames => const Stream.empty();
  @override
  Future<void> start() async => throw UnsupportedError(explanation);
  @override
  Future<void> stop() async {}
}
