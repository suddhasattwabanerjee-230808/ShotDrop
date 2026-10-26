import 'package:flutter/widgets.dart';

import 'models.dart';

/// JPEGs on the SD card are rotated through their source EXIF orientation.
/// RAW-only card photos still need a display turn; phone photos are already
/// upright. Quarter turns clockwise, so 3 = left 90°.
int turnOf(CardFile file) => file.onPhone || file.sourceRotated ? 0 : 3;

/// [child] (a photo of [file]) turned the way ShotDrop shows [file].
class Upright extends StatelessWidget {
  const Upright({super.key, required this.file, required this.child});
  final CardFile file;
  final Widget child;

  @override
  Widget build(BuildContext context) => RotatedBox(quarterTurns: turnOf(file), child: child);
}
