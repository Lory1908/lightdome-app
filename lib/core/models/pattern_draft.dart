import 'dart:convert';

import 'pattern_recipe.dart';

/// Editor metadata compatible with the ESP8266 embedded web UI.
/// The firmware stores this JSON after the LDY1 samples.
class PatternDraft {
  const PatternDraft({
    required this.recipe,
    required this.loop,
    required this.autorun,
  });

  final PatternRecipe recipe;
  final bool loop;
  final bool autorun;

  Map<String, dynamic> toJson() => {
    'preset': recipe.type == PatternRecipeType.organic
        ? 'random'
        : recipe.type.name,
    'duration': recipe.durationSeconds,
    'minimum': (recipe.minimum * 100).round(),
    'maximum': (recipe.maximum * 100).round(),
    'duty': (recipe.duty * 100).round(),
    'easing': recipe.easing == PatternEasing.natural
        ? 'sine'
        : recipe.easing.name,
    'randomness': (recipe.randomness * 100).round(),
    'loop': loop,
    'autorun': autorun,
  };

  String toJsonString() => jsonEncode(toJson());

  factory PatternDraft.fromJson(Map<String, dynamic> json) {
    double number(String key, double minimum, double maximum) {
      final raw = json[key];
      if (raw is! num ||
          !raw.toDouble().isFinite ||
          raw < minimum ||
          raw > maximum) {
        throw FormatException('Parametro non valido: $key');
      }
      return raw.toDouble();
    }

    bool boolean(String key) {
      final raw = json[key];
      if (raw is! bool) throw FormatException('Parametro non valido: $key');
      return raw;
    }

    final preset = json['preset'];
    final type = switch (preset) {
      'breath' => PatternRecipeType.breath,
      'pulse' => PatternRecipeType.pulse,
      'sunrise' => PatternRecipeType.sunrise,
      'random' || 'organic' => PatternRecipeType.organic,
      _ => throw const FormatException('Tipo di pattern sconosciuto'),
    };
    final easing = switch (json['easing']) {
      'smooth' => PatternEasing.smooth,
      'sine' || 'natural' => PatternEasing.natural,
      'linear' => PatternEasing.linear,
      'sharp' => PatternEasing.sharp,
      _ => throw const FormatException('Movimento sconosciuto'),
    };
    final duration = number('duration', 1, 20);
    final min = number('minimum', 0, 90);
    final max = number('maximum', 10, 100);
    if (min > max) throw const FormatException('Minimo maggiore del massimo');
    return PatternDraft(
      recipe: PatternRecipe(
        type: type,
        durationSeconds: duration,
        minimum: min / 100,
        maximum: max / 100,
        duty: number('duty', 5, 95) / 100,
        easing: easing,
        randomness: number('randomness', 0, 100) / 100,
      ),
      loop: boolean('loop'),
      autorun: boolean('autorun'),
    );
  }

  /// No metadata is available on an old LDY file. Values are estimates, not
  /// a reconstruction of the original waveform.
  factory PatternDraft.legacy(String name) {
    final lower = name.toLowerCase();
    final type = lower.contains('batt')
        ? PatternRecipeType.pulse
        : lower.contains('alb')
        ? PatternRecipeType.sunrise
        : lower.contains('organ')
        ? PatternRecipeType.organic
        : PatternRecipeType.breath;
    return PatternDraft(
      recipe: PatternRecipe(
        type: type,
        durationSeconds: 4,
        minimum: .08,
        maximum: 1,
        duty: .5,
        easing: PatternEasing.smooth,
        randomness: .2,
      ),
      loop: false,
      autorun: false,
    );
  }
}
