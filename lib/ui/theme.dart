import 'package:flutter/material.dart';

/// The "On Air" palette. One accent, like a studio tally light.
abstract final class OnAir {
  static const ground = Color(0xFF0E1116);
  static const panel = Color(0xFF151A21);
  static const raised = Color(0xFF1E242D);
  static const line = Color(0xFF2B323D);
  static const fieldLine = Color(0xFF3A4250);
  static const text = Color(0xFFF0F2F5);
  static const body = Color(0xFFC7CED8);
  static const muted = Color(0xFFA3ADBA);
  static const accent = Color(0xFFFFB224);
  static const accentInk = Color(0xFF1A1204);
  static const accentSoft = Color(0xFF2A2415);
  static const accentText = Color(0xFFFFD27A);
  static const airing = Color(0xFF3A2F12);

  /// Fallback tiles for channels and posters without artwork.
  static const tiles = [
    Color(0xFF7FB7FF), Color(0xFF8DE0C0), Color(0xFFFF9EC4), Color(0xFFC6B6FF),
    Color(0xFF9BE1F0), Color(0xFFFFC6A0), Color(0xFFD5E58A), Color(0xFFFFB224),
  ];
}

TextStyle heading(double size) => TextStyle(
      fontFamily: 'Space Grotesk',
      fontSize: size,
      fontWeight: FontWeight.w600,
      height: 1.15,
      color: OnAir.text,
    );

ThemeData onAirTheme() {
  const radius12 = BorderRadius.all(Radius.circular(12));
  const scheme = ColorScheme.dark(
    primary: OnAir.accent,
    onPrimary: OnAir.accentInk,
    secondary: OnAir.accent,
    onSecondary: OnAir.accentInk,
    surface: OnAir.ground,
    onSurface: OnAir.text,
    onSurfaceVariant: OnAir.muted,
    outline: OnAir.line,
    surfaceContainerHighest: OnAir.raised,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: OnAir.ground,
    fontFamily: 'Inter',
    dividerColor: OnAir.line,
    iconTheme: const IconThemeData(color: OnAir.text),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: OnAir.raised,
      hintStyle: TextStyle(color: OnAir.muted),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: radius12, borderSide: BorderSide.none),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: OnAir.accent,
        foregroundColor: OnAir.accentInk,
        disabledBackgroundColor: OnAir.raised,
        disabledForegroundColor: OnAir.muted,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const RoundedRectangleBorder(borderRadius: radius12),
        // A button's text style replaces the theme's, family included.
        textStyle:
            const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OnAir.text,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: OnAir.line),
        shape: const RoundedRectangleBorder(borderRadius: radius12),
        textStyle:
            const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: OnAir.text,
        minimumSize: const Size(0, 46),
        shape: const RoundedRectangleBorder(borderRadius: radius12),
      ),
    ),
    // By selection only, so a locked choice still shows which it is.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? OnAir.accentSoft
                : OnAir.ground),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? OnAir.accent : OnAir.muted),
        side: const WidgetStatePropertyAll(BorderSide(color: OnAir.line)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: OnAir.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: OnAir.line),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: OnAir.panel,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: OnAir.raised,
      surfaceTintColor: Colors.transparent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? OnAir.accentInk : OnAir.muted),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? OnAir.accent : OnAir.line),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: OnAir.accent,
      thumbColor: OnAir.accent,
      inactiveTrackColor: Color(0x40FFFFFF),
      trackHeight: 4,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: OnAir.raised,
      contentTextStyle: TextStyle(color: OnAir.text),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: OnAir.accent),
  );
}
