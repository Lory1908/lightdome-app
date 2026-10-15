import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

typedef MicLevelCallback = void Function(double y01);

double pcm16Rms(Uint8List bytes) {
  final sampleCount = bytes.lengthInBytes ~/ 2;
  if (sampleCount == 0) return 0;
  final data = ByteData.sublistView(bytes);
  double energy = 0;
  for (var i = 0; i < sampleCount; i++) {
    final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
    energy += sample * sample;
  }
  return math.sqrt(energy / sampleCount).clamp(0.0, 1.0);
}

class MicReactiveService {
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  Future<bool> _ensure() async => await _rec.hasPermission();

  double _env = 0; // smoothed envelope 0..1

  Future<void> start(
    MicLevelCallback onLevel, {
    double threshold = 0.02,
    double attack = 0.65,
    double release = 0.3,
  }) async {
    if (!await _ensure()) return;
    if (await _rec.isRecording()) {
      await _rec.stop();
    }
    _env = 0;
    const cfg = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      streamBufferSize: 1024,
    );
    final stream = await _rec.startStream(cfg);
    await _sub?.cancel();
    _sub = stream.listen((bytes) {
      var lin = pcm16Rms(bytes);
      // Noise gate
      if (lin < threshold) lin = 0.0;
      // Attack/Release smoothing (EMA) on linear amplitude
      final alphaUp = attack.clamp(0.0, 1.0);
      final alphaDown = release.clamp(0.0, 1.0);
      final target = lin;
      if (target >= _env) {
        _env = _env + (target - _env) * alphaUp;
      } else {
        _env = _env + (target - _env) * alphaDown;
      }
      // perceptual curve for LED response
      final perceptual = math.pow(_env, 0.6).toDouble();
      onLevel(perceptual.clamp(0.0, 1.0));
    });
  }

  Future<void> stop() async {
    await _rec.stop();
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
  }
}
