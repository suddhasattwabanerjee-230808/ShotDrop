import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'story.dart';

/// Instagram feed posts must sit between 4:5 (tallest) and 1.91:1 (widest),
/// and every photo in a carousel takes the first one's shape. Photos that
/// don't fit are sent in a shape that does, made one of two ways.
enum PostFit {
  crop('Crop To Fit', 'Trims the photo; tall ones keep more of the top'),
  borders('Add Borders', 'Keeps the whole photo, over a blurred copy of itself');

  const PostFit(this.label, this.detail);
  final String label, detail;
}

const postMinAspect = 0.8, postMaxAspect = 1.91;

/// The shape every photo of one post goes out in: the first photo's, within
/// Instagram's limits.
double postAspect(List<double> aspects) => aspects.first.clamp(postMinAspect, postMaxAspect);

/// Whether a photo of [aspect] has to be reshaped to go out as [target].
bool needsReshape(double aspect, double target) => (aspect / target - 1).abs() > 0.01;

/// How much of the cut is taken from the top of a tall photo: less than
/// half, since faces are usually up there.
const cropAnchorY = 0.35;

/// Pixel size of a photo of [photo] made [target] by [fit], at most [maxEdge] on its long side.
Size reshapedSize(Size photo, double target, PostFit fit, {int maxEdge = 2160}) {
  final wider = photo.width / photo.height > target;
  // Cropping keeps the shorter side whole; borders keep the longer.
  final w = wider == (fit == PostFit.crop) ? photo.height * target : photo.width;
  final h = w / target;
  final k = math.min(1.0, maxEdge / math.max(w, h));
  return Size((w * k).roundToDouble(), (h * k).roundToDouble());
}

/// [photo] made [target] (width / height) by [fit].
Future<ui.Image> renderReshaped(ui.Image photo, double target, PostFit fit, {int maxEdge = 2160}) {
  final size = reshapedSize(Size(photo.width.toDouble(), photo.height.toDouble()), target, fit, maxEdge: maxEdge);
  return renderFramed(photo, size, fill: fit == PostFit.crop, anchorY: cropAnchorY);
}
