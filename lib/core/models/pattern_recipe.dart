import 'dart:math' as math;

enum PatternRecipeType { breath, pulse, sunrise, organic }

enum PatternEasing { smooth, natural, linear, sharp }

class PatternRecipe {
  const PatternRecipe({
    required this.type,
    required this.durationSeconds,
    required this.minimum,
    required this.maximum,
    required this.duty,
    required this.easing,
    required this.randomness,
    this.sampleRateHz = 250,
  });

  final PatternRecipeType type;
  final double durationSeconds;
  final double minimum;
  final double maximum;
  final double duty;
  final PatternEasing easing;
  final double randomness;
  final int sampleRateHz;

  List<int> render() {
    final count = math.max(2, (durationSeconds * sampleRateHz).round());
    return List<int>.generate(count, (index) {
      final t = index / (count - 1);
      return (valueAt(t) * 1023).round().clamp(0, 1023);
    }, growable: false);
  }

  double valueAt(double progress) {
    final t = progress.clamp(0.0, 1.0);
    final low = minimum.clamp(0.0, 1.0);
    final high = math.max(low, maximum.clamp(0.0, 1.0));
    double normalized;
    switch (type) {
      case PatternRecipeType.sunrise:
        normalized = _ease(t);
        break;
      case PatternRecipeType.pulse:
        const edge = 0.12;
        if (t >= duty) {
          normalized = 0;
        } else {
          final relative = t / duty.clamp(0.05, 0.95);
          if (relative < edge) {
            normalized = _ease(relative / edge);
          } else if (relative > 1 - edge) {
            normalized = 1 - _ease((relative - 1 + edge) / edge);
          } else {
            normalized = 1;
          }
        }
        break;
      case PatternRecipeType.organic:
        final wobble =
            (math.sin(t * 19.7) +
                    math.sin(t * 43.1) * .45 +
                    math.sin(t * 7.3) * .7) /
                2.15 *
                .5 +
            .5;
        final breath = (1 - math.cos(t * math.pi * 2)) / 2;
        normalized = breath * (1 - randomness) + wobble * randomness;
        break;
      case PatternRecipeType.breath:
        final wave = (1 - math.cos(t * math.pi * 2)) / 2;
        normalized = _ease(wave);
        break;
    }
    return low + (high - low) * normalized.clamp(0.0, 1.0);
  }

  double _ease(double input) {
    final t = input.clamp(0.0, 1.0);
    return switch (easing) {
      PatternEasing.linear => t,
      PatternEasing.natural => -(math.cos(math.pi * t) - 1) / 2,
      PatternEasing.sharp =>
        t < .5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2).toDouble() / 2,
      PatternEasing.smooth => t * t * (3 - 2 * t),
    };
  }
}
