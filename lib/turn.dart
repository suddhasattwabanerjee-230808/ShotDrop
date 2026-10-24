import 'package:flutter/widgets.dart';

import 'models.dart';

/// SD card photos are shown and used turned 90° left: in the galleries, the
/// viewer, Selected, the editor and sharing. Phone photos are already the
/// right way up. Quarter turns clockwise, so 3 = left 90°.
int turnOf(CardFile file) => file.onPhone ? 0 : 3;

/// [child] (a photo of [file]) turned the way ShotDrop shows [file].
class Upright extends StatelessWidget {
  const Upright({super.key, required this.file, required this.child});
  final CardFile file;
  final Widget child;

  @override
  Widget build(BuildContext context) => RotatedBox(quarterTurns: turnOf(file), child: child);
}
