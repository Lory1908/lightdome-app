import 'dart:async';

/// Audio capture is opt-in. Implementations must never report simulated
/// samples as real system sound.
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
  const UnavailableSystemAudioSource({
    this.explanationText =
        'Cattura del sistema non disponibile su questa piattaforma; nessuna registrazione è in corso.',
  });

  final String explanationText;

  @override
  String get label => 'Audio del computer';
  @override
  bool get isSupported => false;
  @override
  String get explanation => explanationText;
  @override
  Stream<AudioPcmChunk> get frames => const Stream.empty();
  @override
  Future<void> start() async => throw UnsupportedError(explanation);
  @override
  Future<void> stop() async {}
}
