import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_services.dart';
import 'seniornav_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _startApplication();
}

Future<void> _startApplication() async {
  try {
    final services = await createAppServices();
    runApp(SeniorNavApp(services: services));
  } catch (_) {
    // Storage errors may include private file paths or values. Keep the launch
    // screen readable and never clear the database or retry automatically.
    runApp(StartupFailureApp(onRetry: _startApplication));
  }
}

class StartupFailureApp extends StatefulWidget {
  const StartupFailureApp({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp> {
  bool _busy = false;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // Preserve the same safe message if a caller's initialization fails.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SeniorNav',
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1465D8)),
    ),
    home: Scaffold(
      backgroundColor: const Color(0xFFF5F8FD),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 52,
                    color: Color(0xFF1453A1),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '暂时无法打开常用地点',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    '请让家人检查手机存储空间后，再重新打开。\n\n应用不会自动清除地点数据。',
                    style: TextStyle(fontSize: 22, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    key: const ValueKey('retry-startup'),
                    onPressed: _busy ? null : _retry,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 72),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 20,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: Text(
                      _busy ? '正在打开…' : '重新打开',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
