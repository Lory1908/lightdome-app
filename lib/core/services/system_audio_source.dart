import 'audio_capture_source.dart';
import 'system_audio_source_stub.dart'
    if (dart.library.io) 'system_audio_source_io.dart'
    as implementation;

AudioCaptureSource createSystemAudioSource() =>
    implementation.createSystemAudioSource();
