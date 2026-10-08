import 'dart:math' as math;

import 'audio_capture_source.dart';

class AudioTuning {
  const AudioTuning({
    this.gain = 1.0,
    this.gate = .05,
    this.attack = .65,
    this.release = .3,
    this.minimum = 0,
    this.maximum = 1,
    this.volumeWeight = .4,
    this.bassWeight = .35,
    this.midWeight = .15,
    this.trebleWeight = .1,
    this.beatBoost = .15,
  });

  final double gain;
  final double gate;
  final double attack;
  final double release;
  final double minimum;
  final double maximum;
  final double volumeWeight;
  final double bassWeight;
  final double midWeight;
  final double trebleWeight;
  final double beatBoost;
}

class AudioFeatures {
  const AudioFeatures({
    required this.volume,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.beat,
    required this.intensity,
  });

  final double volume;
  final double bass;
  final double mid;
  final double treble;
  final bool beat;
  final double intensity;
}

/// Pure Dart analysis layer. A native adapter supplies PCM; no microphone,
/// browser permission or OS capture is implicitly activated.
class AudioFeatureProcessor {
  AudioFeatureProcessor({this.tuning = const AudioTuning()});

  AudioTuning tuning;
  double _envelope = 0;
  double _recentBass = .02;

  AudioFeatures process(AudioPcmChunk chunk) {
    final input = chunk.samples;
    final sr = chunk.sampleRateHz;
    if (sr < 8000 || input.length < 64 || input.length > 8192) {
      throw const FormatException('Formato PCM non supportato');
    }

    // RMS amplitude and a Hann-windowed, small Goertzel filter bank.
    final n = input.length;
    double energy = 0;
    final windowed = List<double>.generate(n, (i) {
      final x = input[i];
      if (!x.isFinite || x.abs() > 1.001) {
        throw const FormatException('Campioni PCM non validi');
      }
      energy += x * x;
      return x * (.5 - .5 * math.cos(2 * math.pi * i / (n - 1)));
    }, growable: false);
    final volume = math.sqrt(energy / n).clamp(0.0, 1.0);
    double band(List<double> frequencies) {
      double sum = 0;
      var used = 0;
      for (final hz in frequencies) {
        if (hz >= sr / 2) continue;
        final coeff = 2 * math.cos(2 * math.pi * hz / sr);
        double a = 0, b = 0;
        for (final sample in windowed) {
          final next = sample + coeff * a - b;
          b = a;
          a = next;
        }
        final power = math.max(0, a * a + b * b - coeff * a * b);
        sum += (2 * math.sqrt(power) / n).clamp(0.0, 1.0);
        used++;
      }
      return used == 0 ? 0 : (sum / used).clamp(0.0, 1.0);
    }

    final bass = band(const [55, 110, 180]);
    final mid = band(const [380, 750, 1500]);
    final treble = band(const [2700, 4400, 6500]);
    final beat = bass > .055 && bass > _recentBass * 1.6;
    _recentBass = .92 * _recentBass + .08 * bass;

    final volumeWeight = tuning.volumeWeight.clamp(0.0, 1.0);
    final bassWeight = tuning.bassWeight.clamp(0.0, 1.0);
    final midWeight = tuning.midWeight.clamp(0.0, 1.0);
    final trebleWeight = tuning.trebleWeight.clamp(0.0, 1.0);
    final weightTotal = volumeWeight + bassWeight + midWeight + trebleWeight;
    var drive = weightTotal <= 0
        ? volume
        : (volume * volumeWeight +
                  bass * bassWeight +
                  mid * midWeight +
                  treble * trebleWeight) /
              weightTotal;
    if (beat) drive = (drive + tuning.beatBoost.clamp(0.0, 1.0)).clamp(0, 1);

    final gated = drive < tuning.gate
        ? 0.0
        : (drive * tuning.gain).clamp(0.0, 1.0);
    final alpha = (gated > _envelope ? tuning.attack : tuning.release).clamp(
      0.0,
      1.0,
    );
    _envelope += (gated - _envelope) * alpha;
    final floor = tuning.minimum.clamp(0.0, 1.0);
    final ceiling = tuning.maximum.clamp(floor, 1.0);
    final intensity = floor + (ceiling - floor) * _envelope;
    return AudioFeatures(
      volume: volume,
      bass: bass,
      mid: mid,
      treble: treble,
      beat: beat,
      intensity: intensity,
    );
  }

  void reset() {
    _envelope = 0;
    _recentBass = .02;
  }
}
