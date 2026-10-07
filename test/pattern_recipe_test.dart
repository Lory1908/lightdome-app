import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/models/pattern_recipe.dart';

void main() {
  test('breath recipe stays in range and closes the loop', () {
    const recipe = PatternRecipe(
      type: PatternRecipeType.breath,
      durationSeconds: 4,
      minimum: .08,
      maximum: 1,
      duty: .5,
      easing: PatternEasing.smooth,
      randomness: .2,
      sampleRateHz: 100,
    );
    final samples = recipe.render();
    expect(samples, hasLength(400));
    expect(samples.every((value) => value >= 0 && value <= 1023), isTrue);
    expect((samples.first - samples.last).abs(), lessThanOrEqualTo(1));
    expect(samples.reduce((a, b) => a > b ? a : b), greaterThan(1000));
  });

  test('sunrise recipe is monotonic', () {
    const recipe = PatternRecipe(
      type: PatternRecipeType.sunrise,
      durationSeconds: 2,
      minimum: 0,
      maximum: 1,
      duty: .5,
      easing: PatternEasing.natural,
      randomness: 0,
      sampleRateHz: 50,
    );
    final samples = recipe.render();
    for (var i = 1; i < samples.length; i++) {
      expect(samples[i], greaterThanOrEqualTo(samples[i - 1]));
    }
  });
}
