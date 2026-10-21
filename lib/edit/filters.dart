import '../models.dart';

/// Colour filters as 4x5 colour matrices (the format ColorFilter.matrix and
/// Android's ColorMatrix use: rows R, G, B, A; offsets in 0..255).
typedef ColorMatrix = List<double>;

const ColorMatrix identityMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// [a] applied after [b].
ColorMatrix multiply(ColorMatrix a, ColorMatrix b) {
  final out = List<double>.filled(20, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 5; c++) {
      var v = c == 4 ? a[r * 5 + 4] : 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[r * 5 + k] * b[k * 5 + c];
      }
      out[r * 5 + c] = v;
    }
  }
  return out;
}

ColorMatrix chain(List<ColorMatrix> steps) => steps.fold(identityMatrix, (acc, m) => multiply(m, acc));

ColorMatrix brightnessMatrix(double v) {
  final o = v * 60;
  return [1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0];
}

ColorMatrix contrastMatrix(double v) {
  final s = 1 + v * 0.6;
  final o = 128 * (1 - s);
  return [s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0];
}

/// [s] = 1 keeps colours, 0 is greyscale, > 1 is more vivid.
ColorMatrix saturationMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final i = 1 - s;
  return [
    lr * i + s, lg * i, lb * i, 0, 0, //
    lr * i, lg * i + s, lb * i, 0, 0, //
    lr * i, lg * i, lb * i + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// > 0 warmer (more red/yellow), < 0 cooler (more blue).
ColorMatrix warmthMatrix(double v) => [
  1 + v * 0.12, 0, 0, 0, v * 12, //
  0, 1 + v * 0.03, 0, 0, v * 4, //
  0, 0, 1 - v * 0.12, 0, -v * 12, //
  0, 0, 0, 1, 0, //
];

/// Lifts the blacks and lowers the whites, for a matte look.
ColorMatrix fadeMatrix(double v) {
  final s = 1 - v * 0.2;
  final o = v * 30;
  return [s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0];
}

class FilterPreset {
  const FilterPreset(this.id, this.label, this.build);
  final String id;
  final String label;
  final ColorMatrix Function() build;
}

final filterPresets = <FilterPreset>[
  FilterPreset('original', 'Original', () => identityMatrix),
  FilterPreset('vivid', 'Vivid', () => chain([saturationMatrix(1.35), contrastMatrix(0.15)])),
  FilterPreset('warm', 'Golden', () => chain([warmthMatrix(0.7), saturationMatrix(1.1)])),
  FilterPreset('cool', 'Cool', () => chain([warmthMatrix(-0.6), contrastMatrix(0.05)])),
  FilterPreset('fade', 'Matte', () => chain([fadeMatrix(0.7), saturationMatrix(0.85)])),
  FilterPreset('drama', 'Drama', () => chain([contrastMatrix(0.45), saturationMatrix(0.85), brightnessMatrix(-0.1)])),
  FilterPreset('film', 'Film', () => chain([fadeMatrix(0.4), warmthMatrix(0.35), saturationMatrix(0.9)])),
  FilterPreset('mono', 'Mono', () => chain([saturationMatrix(0), contrastMatrix(0.2)])),
  FilterPreset('noir', 'Noir', () => chain([saturationMatrix(0), contrastMatrix(0.55), brightnessMatrix(-0.12)])),
];

FilterPreset presetById(String id) => filterPresets.firstWhere((p) => p.id == id, orElse: () => filterPresets.first);

/// The full colour change for an edit: the preset first, then the sliders.
ColorMatrix matrixFor(EditParams p) => chain([
  presetById(p.filter).build(),
  brightnessMatrix(p.brightness),
  contrastMatrix(p.contrast),
  saturationMatrix(1 + p.saturation),
  warmthMatrix(p.warmth),
]);

bool isIdentity(ColorMatrix m) {
  for (var i = 0; i < 20; i++) {
    if ((m[i] - identityMatrix[i]).abs() > 1e-6) return false;
  }
  return true;
}
