import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/contracts.dart';
import 'features/home/home_page.dart';

class SeniorNavApp extends StatelessWidget {
  const SeniorNavApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1465D8),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'SeniorNav',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF5F8FD),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 22, height: 1.45),
          bodyMedium: TextStyle(fontSize: 20, height: 1.4),
          bodySmall: TextStyle(fontSize: 18, height: 1.35),
          titleLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F8FD),
          foregroundColor: Color(0xFF16335B),
          centerTitle: false,
          toolbarHeight: 80,
          titleTextStyle: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: Color(0xFF16335B),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(72, 72),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            textStyle: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(72, 72),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
            side: const BorderSide(color: Color(0xFF52749D), width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(72, 72),
            textStyle: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(72, 72)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 20,
          ),
        ),
      ),
      home: HomePage(services: services),
    );
  }
}
