import 'dart:io';

import 'audio_capture_source.dart';
import 'wasapi_loopback_source.dart';

AudioCaptureSource createSystemAudioSource() {
  if (Platform.isWindows) return WasapiLoopbackSource();
  return const UnavailableSystemAudioSource(
    explanationText:
        'L’audio di sistema è disponibile soltanto nell’app Windows.',
  );
}
