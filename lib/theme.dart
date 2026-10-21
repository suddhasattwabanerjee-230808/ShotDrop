import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- Palette ------------------------------------------------------------------
// Always dark, like a camera's own screen: photos read best on near-black.
// One accent, a warm camera yellow, for selection and the main action.

const paper = Color(0xFF0B0B0E); // page background
const surface = Color(0xFF16161B); // cards, sheets, tool panels
const surfaceHigh = Color(0xFF212128); // chips, inputs, raised bits
const ink = Color(0xFFF2F2F5); // primary text
const muted = Color(0xFF9B9BA6); // secondary text, inactive icons
const line = Color(0xFF2A2A32); // outlines and dividers
const accent = Color(0xFFFFD21F); // selection, primary actions
const onAccent = Color(0xFF16130A); // text on the accent
const positive = Color(0xFF4ADE80); // "in the Upload folder"
const negative = Color(0xFFFF6B6B);

ThemeData appThemeData() {
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark).copyWith(
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
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme, fontFamily: 'Manrope');
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: line,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    appBarTheme: const AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      titleTextStyle: TextStyle(fontFamily: 'Manrope', fontSize: 19, fontWeight: FontWeight.w700, color: ink),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    dialogTheme: const DialogThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(color: surfaceHigh, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(
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
        side: const BorderSide(color: line),
        minimumSize: const Size(48, 52),
        textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 15, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: line,
      thumbColor: accent,
      overlayColor: Color(0x33FFD21F),
      trackHeight: 3,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceHigh,
      selectedColor: accent,
      side: BorderSide.none,
      labelStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, color: ink),
      secondaryLabelStyle: const TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w800, color: onAccent),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      hintStyle: const TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: accent),
      ),
    ),
  );
}

const sectionLabel = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: muted);
