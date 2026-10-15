import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'bridge_page.dart';
import 'lan_page.dart';
import 'servers_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final pages = [
          ServersPage(controller: c, onBridgeStarted: () => setState(() => _index = 2)),
          LanPage(controller: c),
          BridgePage(controller: c),
        ];
        return Scaffold(
          body: SafeArea(child: IndexedStack(index: _index, children: pages)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns), label: 'Server'),
              const NavigationDestination(icon: Icon(Icons.wifi_find_outlined), selectedIcon: Icon(Icons.wifi_find), label: 'LAN'),
              NavigationDestination(
                icon: Badge(isLabelVisible: c.bridgeRunning, child: const Icon(Icons.swap_horiz)),
                label: 'Bridge',
              ),
            ],
          ),
        );
      },
    );
  }
}
