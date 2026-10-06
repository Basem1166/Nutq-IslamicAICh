import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nutq/core/recitation/feature_extractor.dart';

void main() {
  test('MualemFeatureExtractor defaults to normalizePerBin = true', () {
    final extractor = MualemFeatureExtractor();
    expect(extractor.normalizePerBin, isTrue);
  });

  test('Normalization changes the output features', () {
    final waveform = Float32List.fromList(List.generate(1000, (i) => i / 1000.0));
    
    final extractorNoNorm = MualemFeatureExtractor(normalizePerBin: false);
    final featuresNoNorm = extractorNoNorm.extract(waveform);

    final extractorNorm = MualemFeatureExtractor(normalizePerBin: true);
    final featuresNorm = extractorNorm.extract(waveform);

    expect(featuresNoNorm.features, isNot(equals(featuresNorm.features)));
  });
}
