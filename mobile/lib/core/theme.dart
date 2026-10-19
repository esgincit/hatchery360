import 'package:flutter/material.dart';

/// Egg-yolk amber accent on a warm straw neutral; large tap targets for shed use.
ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFD9870F), brightness: b,
      surface: dark ? const Color(0xFF211B13) : const Color(0xFFFFFDF8));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF17130D) : const Color(0xFFF3EFE6),
    visualDensity: VisualDensity.comfortable,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: false),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
    cardTheme: CardTheme(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant))),
  );
}

/// Semantic colours for RAG status, separate from the accent.
class Rag {
  static const good = Color(0xFF2F7D4A);
  static const warn = Color(0xFFB6700A);
  static const crit = Color(0xFFB3362B);
}
