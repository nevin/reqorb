import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Text style for anything the user reads as code: URLs, headers, bodies.
/// The fallbacks cover platforms that do not ship Menlo.
const mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'DejaVu Sans Mono', 'monospace'],
  fontSize: 13,
  height: 1.4,
);

/// Whether the app is driven by a pointer and keyboard rather than touch.
bool get isDesktop => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// The label for a shortcut's modifier key on this platform.
String get shortcutModifier =>
    defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS
    ? '⌘'
    : 'Ctrl+';

/// The colour an HTTP method is shown in everywhere, so a request can be
/// recognised by colour before its name is read.
Color methodColor(String method, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (method.toUpperCase()) {
    'GET' => dark ? const Color(0xFF6CCB8B) : const Color(0xFF1A7F42),
    'POST' => dark ? const Color(0xFFE5B454) : const Color(0xFF9A6700),
    'PUT' => dark ? const Color(0xFF6CB1F2) : const Color(0xFF0B63C5),
    'PATCH' => dark ? const Color(0xFFB79BF2) : const Color(0xFF6E43C9),
    'DELETE' => dark ? const Color(0xFFF08A82) : const Color(0xFFC0362C),
    'WS' => dark ? const Color(0xFF5CC8C2) : const Color(0xFF0F766E),
    'GRPC' => dark ? const Color(0xFFF2A0C8) : const Color(0xFFB0307A),
    _ => dark ? const Color(0xFFA9B1BC) : const Color(0xFF59636E),
  };
}

/// The colour for a response status: success, redirect, or failure.
Color statusColor(int status, ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  if (status >= 400) return scheme.error;
  if (status >= 300) return methodColor('POST', scheme.brightness);
  return dark ? const Color(0xFF6CCB8B) : const Color(0xFF1A7F42);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B5BD6),
    brightness: brightness,
  );
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: color, width: width),
      );
  return ThemeData(
    colorScheme: scheme,
    // Pointer-driven platforms get tighter rows; touch keeps full-size targets.
    visualDensity: isDesktop ? VisualDensity.compact : VisualDensity.standard,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: border(scheme.outlineVariant),
      enabledBorder: border(scheme.outlineVariant),
      focusedBorder: border(scheme.primary, 1.5),
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      dividerColor: scheme.outlineVariant,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 13),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 420,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
