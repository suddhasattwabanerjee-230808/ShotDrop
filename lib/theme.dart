import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- Palette ------------------------------------------------------------------
// Playful, like a kids' app: candy colours, a rounded typeface (Fredoka),
// chunky buttons that sit on a darker "lip", and confetti behind the tabs.
// Dark is a grape night sky; light (the sun / moon button on every screen) is
// a warm cream playroom. One accent, bubblegum pink, for selection and the
// main action; the rainbow colours below give each tab and section its own.
//
// These are getters, not constants, so they follow the mode: when it flips,
// ShotDropApp rebuilds every widget (see rebuildAll in main.dart).

bool _light = false;

/// Whether the light colours are in use.
bool get isLight => _light;

/// Picks the colours the app paints with from now on.
void usePalette({required bool light}) => _light = light;

Color _pick(int dark, int light) => Color(_light ? light : dark);

Color get paper => _pick(0xFF1B1238, 0xFFFFF7EC); // page background
Color get surface => _pick(0xFF281B4F, 0xFFFFFFFF); // cards, sheets, tool panels
Color get surfaceHigh => _pick(0xFF36275F, 0xFFFFEEDB); // chips, inputs, raised bits
Color get ink => _pick(0xFFFFF6EC, 0xFF2D1E4F); // primary text
Color get muted => _pick(0xFFB6A8D8, 0xFF85779F); // secondary text, inactive icons
Color get line => _pick(0xFF43347A, 0xFFF0DEC6); // outlines and dividers
Color get accent => _pick(0xFFFF4FA3, 0xFFF0418C); // selection, primary actions
const onAccent = Color(0xFFFFFFFF); // text on the accent
Color get positive => _pick(0xFF3EE08F, 0xFF1FAF66); // "in the Upload folder"
Color get negative => _pick(0xFFFF6B6B, 0xFFE5484D);

// The rainbow: a colour per tab, per settings section, per day in the gallery.
Color get tangerine => _pick(0xFFFFA43A, 0xFFFF8A1F);
Color get sunny => _pick(0xFFFFD84D, 0xFFFFC21A);
Color get grass => _pick(0xFF4BE08A, 0xFF22B868);
Color get sky => _pick(0xFF5BB8FF, 0xFF2F9BF0);
Color get grape => _pick(0xFFA98BFF, 0xFF8B5CF6);
Color get coral => _pick(0xFFFF7A7A, 0xFFFF5C5C);

List<Color> get rainbow => [accent, tangerine, sunny, grass, sky, grape];

/// Text and icons on a rainbow colour: white, except on the light yellow.
Color onFun(Color c) => c == sunny ? const Color(0xFF3A2A00) : Colors.white;

/// The darker shade under a chunky button or card, its "lip".
Color deeper(Color c, [double by = 0.14]) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness - by).clamp(0.0, 1.0)).toColor();
}

/// The colour behind the lip of a raised card: a touch darker than its edge.
Color get cardLip => _light ? const Color(0xFFEBD3B4) : const Color(0xFF120B29);

const _font = 'Fredoka';

ThemeData appThemeData() {
  final brightness = _light ? Brightness.light : Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
    primary: accent,
    onPrimary: onAccent,
    secondary: grape,
    onSecondary: Colors.white,
    tertiary: tangerine,
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerHighest: surfaceHigh,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainer: surface,
    outline: line,
    outlineVariant: line,
    error: negative,
  );
  final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, fontFamily: _font);
  WidgetStateProperty<OutlinedBorder> chunky(Color face, {double radius = 20, BorderSide side = BorderSide.none}) =>
      WidgetStateProperty.resolveWith(
        (states) => ChunkyBorder(
          borderRadius: BorderRadius.circular(radius),
          side: side,
          // Pressed: the button sinks onto its lip.
          depth: states.contains(WidgetState.pressed) ? 1.5 : 4.5,
          lip: states.contains(WidgetState.disabled) ? line : deeper(face),
        ),
      );
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: line,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    appBarTheme: AppBarTheme(
      // See-through, so the confetti behind the tabs shows under the title.
      backgroundColor: Colors.transparent,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: _light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      titleTextStyle: TextStyle(fontFamily: _font, fontSize: 24, fontWeight: FontWeight.w700, color: ink),
    ),
    iconTheme: IconThemeData(color: ink),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: accent.withValues(alpha: 0.6),
      dragHandleSize: const Size(44, 6),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
        side: BorderSide(color: line, width: 2),
      ),
      titleTextStyle: TextStyle(fontFamily: _font, fontSize: 22, fontWeight: FontWeight.w700, color: ink),
      contentTextStyle: TextStyle(fontFamily: _font, fontSize: 15, height: 1.4, color: muted),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: _light ? const Color(0xFF6A45E8) : const Color(0xFF7B5CFF),
      contentTextStyle: const TextStyle(
        fontFamily: _font,
        color: Colors.white,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
      actionTextColor: const Color(0xFFFFE066),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        disabledBackgroundColor: surfaceHigh,
        disabledForegroundColor: muted,
        minimumSize: const Size(48, 54),
        textStyle: const TextStyle(fontFamily: _font, fontSize: 17, fontWeight: FontWeight.w700),
      ).copyWith(shape: chunky(accent)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        backgroundColor: surface,
        side: BorderSide(color: line, width: 2),
        minimumSize: const Size(48, 54),
        textStyle: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w600),
      ).copyWith(shape: chunky(line)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        textStyle: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w700),
        shape: const StadiumBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : surface),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : ink),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : muted),
        side: WidgetStatePropertyAll(BorderSide(color: line, width: 2)),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        minimumSize: const WidgetStatePropertyAll(Size(48, 46)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? grass : surfaceHigh),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? grass : line),
      trackOutlineWidth: const WidgetStatePropertyAll(2),
      thumbIcon: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Icon(Icons.check_rounded, color: grass) : null,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: surfaceHigh,
      circularTrackColor: Colors.transparent,
      refreshBackgroundColor: surface,
      linearMinHeight: 8,
      borderRadius: BorderRadius.circular(8),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w600, color: ink),
      subtitleTextStyle: TextStyle(fontFamily: _font, fontSize: 12.5, color: muted),
    ),
    badgeTheme: const BadgeThemeData(
      textStyle: TextStyle(fontFamily: _font, fontSize: 11, fontWeight: FontWeight.w700),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: surfaceHigh,
      thumbColor: Colors.white,
      overlayColor: accent.withValues(alpha: 0.2),
      trackHeight: 8,
      thumbShape: _RingThumb(accent),
      valueIndicatorColor: grape,
      valueIndicatorTextStyle: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceHigh,
      selectedColor: accent,
      side: BorderSide(color: line, width: 1.5),
      labelStyle: TextStyle(fontFamily: _font, fontWeight: FontWeight.w600, color: ink),
      secondaryLabelStyle: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700, color: onAccent),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      hintStyle: TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: line, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: line, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: accent, width: 2.5),
      ),
    ),
  );
}

TextStyle get sectionLabel =>
    TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: muted);

/// A rounded rectangle sitting on a darker lip [depth] high, like a toy
/// button: the lip is drawn under the shape, so layout doesn't change.
class ChunkyBorder extends RoundedRectangleBorder {
  const ChunkyBorder({super.side, super.borderRadius, this.depth = 4, required this.lip});

  final double depth;
  final Color lip;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (depth > 0) {
      final face = borderRadius.resolve(textDirection).toRRect(rect);
      final under = Path.combine(
        PathOperation.difference,
        Path()..addRRect(face.shift(Offset(0, depth))),
        Path()..addRRect(face),
      );
      canvas.drawPath(under, Paint()..color = lip);
    }
    super.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  ChunkyBorder copyWith({BorderSide? side, BorderRadiusGeometry? borderRadius, double? depth, Color? lip}) =>
      ChunkyBorder(
        side: side ?? this.side,
        borderRadius: borderRadius ?? this.borderRadius,
        depth: depth ?? this.depth,
        lip: lip ?? this.lip,
      );

  @override
  ChunkyBorder scale(double t) =>
      ChunkyBorder(side: side.scale(t), borderRadius: borderRadius * t, depth: depth * t, lip: lip);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is ChunkyBorder ? _lerp(a, this, t) : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is ChunkyBorder ? _lerp(this, b, t) : super.lerpTo(b, t);

  static ChunkyBorder _lerp(ChunkyBorder a, ChunkyBorder b, double t) => ChunkyBorder(
    side: BorderSide.lerp(a.side, b.side, t),
    borderRadius: BorderRadiusGeometry.lerp(a.borderRadius, b.borderRadius, t)!,
    depth: a.depth + (b.depth - a.depth) * t,
    lip: Color.lerp(a.lip, b.lip, t)!,
  );

  @override
  bool operator ==(Object other) =>
      other is ChunkyBorder &&
      other.side == side &&
      other.borderRadius == borderRadius &&
      other.depth == depth &&
      other.lip == lip;

  @override
  int get hashCode => Object.hash(side, borderRadius, depth, lip);
}

/// A slider knob like a candy: white with a thick coloured ring.
class _RingThumb extends SliderComponentShape {
  const _RingThumb(this.ring);
  final Color ring;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.square(26);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final r = 12 + 2 * activationAnimation.value;
    canvas.drawCircle(center + const Offset(0, 2.5), r, Paint()..color = deeper(ring, 0.18));
    canvas.drawCircle(center, r, Paint()..color = ring);
    canvas.drawCircle(center, r - 5, Paint()..color = Colors.white);
  }
}
