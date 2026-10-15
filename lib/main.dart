import 'package:flutter/material.dart';

import 'src/app/controller.dart';
import 'src/ui/home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController()..load();
  runApp(BedrockBridgeApp(controller: controller));
}

class BedrockBridgeApp extends StatelessWidget {
  const BedrockBridgeApp({super.key, required this.controller});

  final AppController controller;

  // Grass green, the colour players connect with Minecraft.
  static const seed = Color(0xFF5D9C3C);

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
          useMaterial3: true,
          cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6)),
        );
    return MaterialApp(
      title: 'BedrockBridge',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeShell(controller: controller),
    );
  }
}
