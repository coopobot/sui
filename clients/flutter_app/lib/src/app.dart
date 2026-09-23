import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'ui/app_controller.dart';
import 'ui/note_shell.dart';

class SuiApp extends StatelessWidget {
  const SuiApp({super.key, required this.repository});

  final NoteRepository repository;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController(repository: repository)..bootstrap(),
      child: MaterialApp(
        title: '随手记 Sui',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E8B57)),
          useMaterial3: true,
        ),
        home: const NoteShell(),
      ),
    );
  }
}