import 'audio_capture_source.dart';

AudioCaptureSource
createSystemAudioSource() => const UnavailableSystemAudioSource(
  explanationText:
      'Il browser non offre una cattura affidabile dell’audio di sistema. Usa l’app Windows.',
);
