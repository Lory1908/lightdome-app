import 'dart:math' as math;

import 'audio_capture_source.dart';

enum AudioResponseProfile { calibrating, music, beat, tone, manual }

extension AudioResponseProfileLabel on AudioResponseProfile {
  String get label => switch (this) {
    AudioResponseProfile.calibrating => 'Calibrazione…',
    AudioResponseProfile.music => 'Musica',
    AudioResponseProfile.beat => 'Battito',
    AudioResponseProfile.tone => 'Tono',
    AudioResponseProfile.manual => 'Manuale',
  };
}

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
    this.adaptive = false,
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
  final bool adaptive;
}

class AudioFeatures {
  const AudioFeatures({
    required this.volume,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.beat,
    required this.intensity,
    required this.profile,
  });

  final double volume;
  final double bass;
  final double mid;
  final double treble;
  final bool beat;
  final double intensity;
  final AudioResponseProfile profile;
}

/// Pure Dart analysis layer. A native adapter supplies PCM; no microphone,
/// browser permission or OS capture is implicitly activated.
class AudioFeatureProcessor {
  AudioFeatureProcessor({this.tuning = const AudioTuning()});

  AudioTuning tuning;
  double _envelope = 0;
  double _recentBass = .02;
  double _recentVolume = .01;
  double _noiseFloor = .01;
  double _recentPeak = .15;
  double _bassTotal = 0;
  double _midTotal = 0;
  double _trebleTotal = 0;
  int _processedFrames = 0;
  int _adaptiveFrames = 0;
  int _activeFrames = 0;
  int _transientFrames = 0;
  bool _hasAdaptiveProfile = false;
  AudioResponseProfile _profile = AudioResponseProfile.calibrating;

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
    if (_processedFrames == 0) {
      _recentBass = bass;
      _recentVolume = volume;
    }
    final bassTransient = bass > .055 && bass > _recentBass * 1.6;
    final broadbandTransient =
        volume > .025 &&
        volume > _recentVolume * 1.55 &&
        volume > _noiseFloor + .025;
    final beat = _processedFrames >= 4 && (bassTransient || broadbandTransient);
    _processedFrames++;
    _recentBass = .92 * _recentBass + .08 * bass;
    _recentVolume = .9 * _recentVolume + .1 * volume;

    if (tuning.adaptive) {
      _observeAdaptiveFrame(
        volume: volume,
        bass: bass,
        mid: mid,
        treble: treble,
        transient: beat,
      );
    } else {
      _profile = AudioResponseProfile.manual;
    }

    var volumeWeight = tuning.volumeWeight.clamp(0.0, 1.0);
    var bassWeight = tuning.bassWeight.clamp(0.0, 1.0);
    var midWeight = tuning.midWeight.clamp(0.0, 1.0);
    var trebleWeight = tuning.trebleWeight.clamp(0.0, 1.0);
    var beatBoost = tuning.beatBoost.clamp(0.0, 1.0);
    if (tuning.adaptive) {
      switch (_profile) {
        case AudioResponseProfile.beat:
          volumeWeight = .35;
          bassWeight = .45;
          midWeight = .1;
          trebleWeight = .1;
          beatBoost = math.max(beatBoost, .22);
        case AudioResponseProfile.tone:
          volumeWeight = .8;
          bassWeight = .07;
          midWeight = .07;
          trebleWeight = .06;
          beatBoost = 0;
        case AudioResponseProfile.calibrating:
        case AudioResponseProfile.music:
          // Keep the physically approved response for normal, continuous
          // music. Automatic mode should only specialize sparse or tonal
          // sources, not make ordinary songs harsher.
          volumeWeight = tuning.volumeWeight.clamp(0.0, 1.0);
          bassWeight = tuning.bassWeight.clamp(0.0, 1.0);
          midWeight = tuning.midWeight.clamp(0.0, 1.0);
          trebleWeight = tuning.trebleWeight.clamp(0.0, 1.0);
        case AudioResponseProfile.manual:
          break;
      }
    }
    final weightTotal = volumeWeight + bassWeight + midWeight + trebleWeight;
    var drive = weightTotal <= 0
        ? volume
        : (volume * volumeWeight +
                  bass * bassWeight +
                  mid * midWeight +
                  treble * trebleWeight) /
              weightTotal;
    if (beat) drive = (drive + beatBoost).clamp(0, 1);

    final specialize =
        tuning.adaptive &&
        (_profile == AudioResponseProfile.beat ||
            _profile == AudioResponseProfile.tone);
    final adaptiveGate = specialize
        ? math.max(tuning.gate, (_noiseFloor * 1.6).clamp(0.0, .3))
        : tuning.gate;
    final adaptiveGain = specialize
        ? (tuning.gain * (.82 / math.max(_recentPeak, .12))).clamp(.5, 3.0)
        : tuning.gain;
    final gated = drive < adaptiveGate
        ? 0.0
        : (drive * adaptiveGain).clamp(0.0, 1.0);
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
      profile: _profile,
    );
  }

  void _observeAdaptiveFrame({
    required double volume,
    required double bass,
    required double mid,
    required double treble,
    required bool transient,
  }) {
    _adaptiveFrames++;
    if (volume > math.max(.025, _noiseFloor + .015)) _activeFrames++;
    if (volume < _noiseFloor) {
      _noiseFloor = .8 * _noiseFloor + .2 * volume;
    } else {
      _noiseFloor = .995 * _noiseFloor + .005 * volume;
    }
    _recentPeak = math.max(volume, _recentPeak * .995);
    _bassTotal += bass;
    _midTotal += mid;
    _trebleTotal += treble;
    if (transient) _transientFrames++;

    // About one second at the current Android capture cadence is enough to
    // choose an initial response. Re-evaluate slowly to follow a new source
    // without changing personality on every musical phrase.
    if (!_hasAdaptiveProfile && _adaptiveFrames < 32) {
      _profile = AudioResponseProfile.calibrating;
      return;
    }
    if ((!_hasAdaptiveProfile && _adaptiveFrames != 32) ||
        (_hasAdaptiveProfile && _adaptiveFrames < 96)) {
      return;
    }

    final bandTotal = _bassTotal + _midTotal + _trebleTotal;
    final dominant = math.max(_bassTotal, math.max(_midTotal, _trebleTotal));
    final dominance = bandTotal <= .0001 ? 0.0 : dominant / bandTotal;
    final activeRatio = _activeFrames / _adaptiveFrames;
    if (dominance > .68 && _transientFrames < 2) {
      _profile = AudioResponseProfile.tone;
    } else if (_transientFrames >= 2 && activeRatio < .65) {
      _profile = AudioResponseProfile.beat;
    } else {
      _profile = AudioResponseProfile.music;
    }
    _hasAdaptiveProfile = true;
    _adaptiveFrames = 0;
    _activeFrames = 0;
    _transientFrames = 0;
    _bassTotal = 0;
    _midTotal = 0;
    _trebleTotal = 0;
  }

  void reset() {
    _envelope = 0;
    _recentBass = .02;
    _recentVolume = .01;
    _noiseFloor = .01;
    _recentPeak = .15;
    _bassTotal = 0;
    _midTotal = 0;
    _trebleTotal = 0;
    _processedFrames = 0;
    _adaptiveFrames = 0;
    _activeFrames = 0;
    _transientFrames = 0;
    _hasAdaptiveProfile = false;
    _profile = AudioResponseProfile.calibrating;
  }
}
