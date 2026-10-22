import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- Palette ------------------------------------------------------------------
// Dark by default, like a camera's own screen: photos read best on near-black.
// Light mode (the sun / moon button on every screen) is a warm paper white.
// One accent, a camera yellow (a deeper gold on white, so it still reads),
// for selection and the main action.
//
// These are getters, not constants, so they follow the mode: when it flips,
// ShotDropApp rebuilds every widget (see rebuildAll in main.dart).

bool _light = false;

/// Whether the light colours are in use.
bool get isLight => _light;

/// Picks the colours the app paints with from now on.
void usePalette({required bool light}) => _light = light;

Color _pick(int dark, int light) => Color(_light ? light : dark);

Color get paper => _pick(0xFF0B0B0E, 0xFFF6F5F2); // page background
Color get surface => _pick(0xFF16161B, 0xFFFFFFFF); // cards, sheets, tool panels
Color get surfaceHigh => _pick(0xFF212128, 0xFFECEBE6); // chips, inputs, raised bits
Color get ink => _pick(0xFFF2F2F5, 0xFF16161B); // primary text
Color get muted => _pick(0xFF9B9BA6, 0xFF62626C); // secondary text, inactive icons
Color get line => _pick(0xFF2A2A32, 0xFFDCDBD5); // outlines and dividers
Color get accent => _pick(0xFFFFD21F, 0xFFC98A00); // selection, primary actions
const onAccent = Color(0xFF16130A); // text on the accent
Color get positive => _pick(0xFF4ADE80, 0xFF16A34A); // "in the Upload folder"
Color get negative => _pick(0xFFFF6B6B, 0xFFD92D2D);

ThemeData appThemeData() {
  final brightness = _light ? Brightness.light : Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
    primary: accent,
    onPrimary: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    surface: surface,
    onSurface: ink,
    surfaceContainerHighest: surfaceHigh,
    outline: line,
    outlineVariant: line,
    error: negative,
  );
  final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, fontFamily: 'Manrope');
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: line,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: _light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      titleTextStyle: TextStyle(fontFamily: 'Manrope', fontSize: 19, fontWeight: FontWeight.w700, color: ink),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: surfaceHigh, surfaceTintColor: Colors.transparent),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surfaceHigh,
      contentTextStyle: TextStyle(fontFamily: 'Manrope', color: ink, fontWeight: FontWeight.w600),
      actionTextColor: accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 16, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: BorderSide(color: line),
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 15, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: line,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.2),
      trackHeight: 3,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceHigh,
      selectedColor: accent,
      side: BorderSide.none,
      labelStyle: TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, color: ink),
      secondaryLabelStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w800, color: onAccent),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      hintStyle: TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent),
      ),
    ),
  );
}

TextStyle get sectionLabel => TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: muted);
