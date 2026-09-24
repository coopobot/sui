import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bootstrap.dart';
import 'ui/app_controller.dart';
import 'ui/note_shell.dart';

class SuiApp extends StatelessWidget {
  const SuiApp({super.key, required this.storage});

  final AppStorage storage;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController(
        repository: storage.repository,
        database: storage.db,
        dataDir: storage.dataDir,
      )..bootstrap(),
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