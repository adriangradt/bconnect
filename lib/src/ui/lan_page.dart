import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'servers_page.dart';
import 'widgets.dart';

class LanPage extends StatelessWidget {
  const LanPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('LAN-Welten')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: c.scanning ? null : c.scanLan,
        icon: c.scanning
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.radar),
        label: Text(c.scanning ? 'Suche läuft …' : 'LAN durchsuchen'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          const MessageCard(
            icon: Icons.info_outline,
            text: 'Findet Minecraft-Bedrock-Welten und -Server in deinem WLAN, genau wie der LAN-Tab im Spiel.',
          ),
          if (broadcastLimited) const MessageCard(icon: Icons.phone_iphone, text: iosBroadcastHint),
          if (c.scanError != null) MessageCard(icon: Icons.error_outline, error: true, text: c.scanError!),
          if (!c.scanning && c.lastScan != null && c.lanServers.isEmpty)
            const MessageCard(
              icon: Icons.search_off,
              text: 'Nichts gefunden. Ist das Gerät im selben WLAN? Gast-WLANs blockieren oft Geräte untereinander.',
            ),
          for (final s in c.lanServers)
            Card(
              child: ListTile(
                leading: Icon(c.isOwnBridge(s) ? Icons.swap_horiz : Icons.public, color: t.colorScheme.primary),
                title: Text(s.name),
                subtitle: Text([
                  if (c.isOwnBridge(s)) 'Diese Bridge',
                  if (s.motd != null && s.motd!.plainLine2.isNotEmpty) s.motd!.plainLine2,
                  s.key,
                  if (s.motd != null) '${s.motd!.players}/${s.motd!.maxPlayers} · ${s.motd!.version}',
                  '${s.latency.inMilliseconds} ms',
                ].join('\n')),
                isThreeLine: true,
                trailing: c.isOwnBridge(s)
                    ? null
                    : IconButton(
                        tooltip: 'Als Server speichern',
                        icon: const Icon(Icons.bookmark_add_outlined),
                        onPressed: () => showServerEditor(
                          context,
                          c,
                          host: s.address.address,
                          port: s.port,
                          name: s.name,
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
