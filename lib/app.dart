import 'package:flutter/material.dart';

import 'features/home/editor_screen.dart';

class QuranReelApp extends StatelessWidget {
  const QuranReelApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Quran Reel Maker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'NotoSans',
      fontFamilyFallback: const ['AmiriQuran'],
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF9EE2C2),
        brightness: Brightness.dark,
        surface: const Color(0xFF141D1D),
      ),
      scaffoldBackgroundColor: const Color(0xFF0E1515),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF101919),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF182222),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      sliderTheme: const SliderThemeData(
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
    ),
    home: const EditorScreen(),
  );
}
