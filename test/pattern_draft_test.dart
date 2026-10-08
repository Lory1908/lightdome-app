import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/models/pattern_draft.dart';
import 'package:lightdome_app/core/models/pattern_recipe.dart';
import 'package:lightdome_app/core/ldy/ldy_encoder.dart';

void main() {
  for (final type in PatternRecipeType.values) {
    test('round trip metadata for ${type.name}', () {
      final draft = PatternDraft(
        recipe: PatternRecipe(
          type: type,
          durationSeconds: 4,
          minimum: .08,
          maximum: .9,
          duty: .35,
          easing: PatternEasing.natural,
          randomness: .55,
        ),
        loop: true,
        autorun: false,
      );
      final decoded = PatternDraft.fromJson(draft.toJson());
      expect(decoded.recipe.type, type);
      expect(decoded.recipe.easing, PatternEasing.natural);
      expect(decoded.recipe.durationSeconds, 4);
      expect(decoded.recipe.minimum, .08);
      expect(decoded.recipe.maximum, .9);
      expect(decoded.recipe.duty, .35);
      expect(decoded.recipe.randomness, .55);
      expect(decoded.loop, isTrue);
      expect(decoded.autorun, isFalse);
    });
  }

  test('embedded WebUI metadata is accepted', () {
    final draft = PatternDraft.fromJson({
      'preset': 'random',
      'duration': 6,
      'minimum': 18,
      'maximum': 82,
      'duty': 50,
      'easing': 'sine',
      'randomness': 55,
      'loop': false,
      'autorun': true,
    });
    expect(draft.recipe.type, PatternRecipeType.organic);
    expect(draft.recipe.easing, PatternEasing.natural);
  });

  test('invalid metadata is rejected, not silently replaced', () {
    final good = PatternDraft.legacy('respiro').toJson();
    expect(
      () => PatternDraft.fromJson({...good, 'duration': 100}),
      throwsFormatException,
    );
    expect(
      () => PatternDraft.fromJson({...good, 'preset': 'script'}),
      throwsFormatException,
    );
    expect(
      () => PatternDraft.fromJson({...good, 'minimum': 90, 'maximum': 10}),
      throwsFormatException,
    );
  });

  test('legacy LDY header stays unchanged and metadata is optional', () {
    final old = LdyEncoder.encode(sampleRateHz: 100, y1023: [0, 1023]);
    expect(old.length, 16);
    expect(old.sublist(0, 4), [76, 68, 89, 49]);
    expect(old[10], 0);
    expect(old[11], 0);
    final draft = PatternDraft.legacy('respiro');
    final newer = LdyEncoder.encode(
      sampleRateHz: 250,
      y1023: [0, 1023],
      recipeMetadata: draft.toJson(),
    );
    final length = newer[10] | (newer[11] << 8);
    expect(length, greaterThan(0));
    final decoded = jsonDecode(utf8.decode(newer.sublist(16)));
    expect(decoded['preset'], 'breath');
    expect(newer.length, 16 + length);
    expect(newer[4] | (newer[5] << 8), 250);
  });
}
