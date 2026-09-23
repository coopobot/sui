import 'package:flutter/material.dart';

import 'home_page.dart';

class SuiApp extends StatelessWidget {
  const SuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '随手记 Sui',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E8B57)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}