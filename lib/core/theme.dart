import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF0E1116);
  static const surface = Color(0xFF171B22);
  static const surfaceHigh = Color(0xFF222832);
  static const accent = Color(0xFF3D8BFF);
  static const focus = Color(0xFFFFC233);
  static const text = Color(0xFFE8ECF2);
  static const textDim = Color(0xFF8E98A8);
  static const danger = Color(0xFFFF6B6B);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(surface: AppColors.surface, primary: AppColors.accent);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    // Keep it light for old laptops: no ink splash animation.
    splashFactory: NoSplash.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
    }),
    appBarTheme: const AppBarTheme(backgroundColor: AppColors.surface, elevation: 0),
    dividerColor: AppColors.surfaceHigh,
    focusColor: AppColors.focus.withValues(alpha: 0.25),
  );
}

/// Sizes that grow in TV mode (readable from ~3 m).
class UiScale {
  const UiScale(this.tv);
  final bool tv;

  double get tileHeight => tv ? 76 : 56;
  double get logoSize => tv ? 56 : 40;
  double get listWidth => tv ? 520 : 380;
  double get groupWidth => tv ? 240 : 170;
  double get textScale => tv ? 1.35 : 1.0;
}
