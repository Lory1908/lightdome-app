import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/services/mic_reactive_service.dart';

Uint8List pcm16Sine(double amplitude, {int samples = 512}) {
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value = (amplitude * math.sin(i * 2 * math.pi * 8 / samples) * 32767)
        .round();
    data.setInt16(i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('PCM microphone RMS is decoded without writing an audio file', () {
    expect(pcm16Rms(Uint8List(0)), 0);
    expect(pcm16Rms(Uint8List(1024)), 0);
    expect(pcm16Rms(pcm16Sine(.8)), closeTo(.8 / math.sqrt(2), .002));
  });
}
