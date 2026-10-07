import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── మన పాత _P క్లాస్ ని AppPalette లాగా మార్చాం ───
class AppPalette {
  const AppPalette({
    required this.bg, required this.bg2, required this.text, required this.sub,
    required this.glass, required this.border, required this.bar, required this.accent, required this.surface,
  });
  final Color bg, bg2, text, sub, glass, border, bar, accent, surface;

  static const dark = AppPalette(
    bg: Color(0xFF090A0F), bg2: Color(0xFF14161F), text: Color(0xFFF4F5FA), sub: Color(0xFF9AA1B5),
    glass: Color(0x14FFFFFF), border: Color(0x26FFFFFF), bar: Color(0x990A0B10), accent: Color(0xFF7C9CFF), surface: Color(0xFF1B1E2A),
  );

  static const light = AppPalette(
    bg: Color(0xFFEDEFF6), bg2: Color(0xFFFFFFFF), text: Color(0xFF12141C), sub: Color(0xFF6B7285),
    glass: Color(0x99FFFFFF), border: Color(0xE6FFFFFF), bar: Color(0xB8FFFFFF), accent: Color(0xFF3D5AFE), surface: Color(0xFFFFFFFF),
  );
}

// ─── Theme Provider State Manager ───
class ThemeProvider extends ChangeNotifier {
  bool _isDark;

  // యాప్ స్టార్ట్ అయినప్పుడు సేవ్ అయిన థీమ్ తోనే ఇనిషియలైజ్ చేస్తాం
  ThemeProvider(this._isDark);

  bool get isDark => _isDark;
  AppPalette get p => _isDark ? AppPalette.dark : AppPalette.light;

  void toggleTheme() async {
    _isDark = !_isDark;
    notifyListeners(); 
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDark', _isDark);
  }
}