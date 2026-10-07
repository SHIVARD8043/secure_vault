import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/theme_provider.dart';
import 'screens/home_gallery_screen.dart';

void main() async {
  // ఇది కచ్చితంగా పెట్టాలి (SharedPreferences ముందే లోడ్ అవ్వడానికి)
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('isDark') ?? true; // సేవ్ అయిన థీమ్ లాగుతున్నాం

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(isDark), // ఆ థీమ్ ని యాప్ కి పంపుతున్నాం
      child: const SecureVaultApp(),
    ),
  );
}

class SecureVaultApp extends StatelessWidget {
  const SecureVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Secure Vault',
      home: const HomeGalleryScreen(),
    );
  }
}