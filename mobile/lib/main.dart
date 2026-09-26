import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/computers.dart';

void main() {
  runApp(const ProviderScope(child: CalcarApp()));
}

class CalcarApp extends StatelessWidget {
  const CalcarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calcar',
      theme: ThemeData(useMaterial3: true),
      home: const ComputersScreen(),
    );
  }
}
