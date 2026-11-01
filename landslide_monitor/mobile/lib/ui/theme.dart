import 'package:flutter/material.dart';

/// Phong cách gần thủy canh / ngưng tụ: nền tối, accent đất/amber + nước.
/// Tránh purple/cream mặc định AI.
class SatloTheme {
  static const Color deep = Color(0xFF0B1210);
  static const Color mist = Color(0xFF14201C);
  static const Color panel = Color(0xFF1B2B24);
  static const Color panelSoft = Color(0xFF243830);
  static const Color amber = Color(0xFFE07A3D);
  static const Color water = Color(0xFF2EC4B6);
  static const Color soil = Color(0xFFC4A35A);
  static const Color soft = Color(0xFFF3F7F4);
  static const Color muted = Color(0xFF9BB0A4);
  static const Color danger = Color(0xFFE85D4C);
  static const Color ok = Color(0xFF3DDC84);

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Roboto',
    );
    final text = base.textTheme.apply(bodyColor: soft, displayColor: soft);
    return base.copyWith(
      scaffoldBackgroundColor: deep,
      colorScheme: const ColorScheme.dark(
        primary: amber,
        secondary: water,
        tertiary: soil,
        surface: panel,
        onPrimary: deep,
        onSecondary: deep,
        onSurface: soft,
        error: danger,
      ),
      textTheme: text.copyWith(
        displayMedium: text.displayMedium?.copyWith(
          color: soft,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.4,
          height: 0.95,
        ),
        titleLarge: text.titleLarge?.copyWith(
          color: soft,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: text.bodyLarge?.copyWith(color: soft, height: 1.4),
        bodyMedium: text.bodyMedium?.copyWith(color: muted, height: 1.35),
      ),
    );
  }

  static BoxDecoration screenGradient() {
    return const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1A2A22),
          deep,
          Color(0xFF0A100E),
          Color(0xFF121C22),
        ],
        stops: [0.0, 0.4, 0.78, 1.0],
      ),
    );
  }
}
