import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../bridge/bridge.dart';
import 'widgets.dart';

class BridgePage extends StatelessWidget {
  const BridgePage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final b = c.bridge;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Bridge')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (broadcastLimited) const MessageCard(icon: Icons.phone_iphone, text: iosBroadcastHint),
          if (c.bridgeError != null) MessageCard(icon: Icons.error_outline, error: true, text: c.bridgeError!),
          if (b == null || !b.isRunning)
            const MessageCard(
              icon: Icons.wifi_tethering_off,
              text: 'Keine Bridge aktiv. Wähle unter „Server“ einen Server und tippe auf „Ins LAN bringen“.',
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    StatusDot(online: b.stats.remoteReachable),
                    const SizedBox(width: 10),
                    Expanded(child: Text(c.bridgedServer?.name ?? '', style: t.textTheme.titleLarge)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    b.stats.remoteReachable
                        ? 'Erscheint im LAN-Tab als „${b.stats.remoteMotd?.plainName ?? ''}“'
                        : 'Remote-Server antwortet nicht – wird im LAN-Tab ausgeblendet',
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    if (b.config.mode == BridgeMode.transfer)
                      InfoChip(icon: Icons.call_made, text: '${b.stats.transfers} weitergeleitet')
                    else
                      InfoChip(icon: Icons.people_outline, text: '${b.stats.activeSessions} verbunden'),
                    if (b.stats.remoteLatency != null)
                      InfoChip(icon: Icons.speed, text: '${b.stats.remoteLatency!.inMilliseconds} ms'),
                    if (b.config.mode == BridgeMode.relay) ...[
                      InfoChip(icon: Icons.upload, text: formatBytes(b.stats.bytesToRemote)),
                      InfoChip(icon: Icons.download, text: formatBytes(b.stats.bytesToClients)),
                    ],
                  ]),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: c.stopBridge,
                    icon: const Icon(Icons.stop),
                    label: const Text('Bridge stoppen'),
                  ),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('So verbindest du dich', style: t.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(b.config.mode == BridgeMode.transfer
                      ? '1. Konsole oder Tablet ins selbe WLAN wie dieses Gerät.\n'
                          '2. Minecraft öffnen → Spielen → Freunde.\n'
                          '3. Unter „LAN-Spiele“ den Server antippen.\n'
                          '4. Kurz erscheint eine leere Welt, dann landest du auf dem Server. '
                          'Ab dann spielt die Konsole direkt mit dem Server – du kannst die App schließen.'
                      : '1. Konsole oder Tablet ins selbe WLAN wie dieses Gerät.\n'
                          '2. Minecraft öffnen → Spielen → Freunde.\n'
                          '3. Unter „LAN-Spiele“ den Server antippen.\n'
                          '4. Dauerhaftes Durchleiten ist an: App während des Spiels offen lassen.'),
                  const SizedBox(height: 12),
                  Text(
                    'Gerät: ${c.localAddresses.map((a) => a.address).join(', ')}\n'
                    'Relay-Port: UDP ${b.proxyPort}\n'
                    'LAN-Erkennung: ${b.discoveryPort != null ? 'UDP ${b.discoveryPort}' : 'nicht verfügbar'}\n'
                    'Ziel: ${b.config.remoteHost}:${b.config.remotePort} (${b.remoteAddress?.address ?? ''})',
                    style: t.textTheme.bodySmall,
                  ),
                ]),
              ),
            ),
          ],
          if (c.bridgeLog.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('Protokoll', style: t.textTheme.titleMedium),
            ),
            for (final e in c.bridgeLog)
              ListTile(
                dense: true,
                leading: Icon(
                  switch (e.level) {
                    BridgeLogLevel.info => Icons.info_outline,
                    BridgeLogLevel.warning => Icons.warning_amber,
                    BridgeLogLevel.error => Icons.error_outline,
                  },
                  color: e.level == BridgeLogLevel.info ? null : t.colorScheme.error,
                ),
                title: Text(e.message),
                subtitle: Text(TimeOfDay.fromDateTime(e.time).format(context)),
              ),
          ],
        ],
      ),
    );
  }
}
