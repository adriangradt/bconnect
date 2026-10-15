import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/models.dart';
import 'widgets.dart';

class ServersPage extends StatelessWidget {
  const ServersPage({super.key, required this.controller, required this.onBridgeStarted});

  final AppController controller;
  final VoidCallback onBridgeStarted;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('BedrockBridge'),
        actions: [
          IconButton(tooltip: 'Alle neu pingen', onPressed: c.pingAll, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showServerEditor(context, c),
        icon: const Icon(Icons.add),
        label: const Text('Server'),
      ),
      body: RefreshIndicator(
        onRefresh: c.pingAll,
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 96),
          children: [
            if (c.bridgeError != null)
              MessageCard(icon: Icons.error_outline, error: true, text: c.bridgeError!),
            if (c.servers.isEmpty)
              const MessageCard(
                icon: Icons.info_outline,
                text: 'Noch kein Server gespeichert. Tippe auf „Server“, um einen Bedrock-Server hinzuzufügen.',
              ),
            for (final s in c.servers)
              _ServerCard(
                server: s,
                status: c.status[s.id],
                active: c.bridgedServer?.id == s.id && (c.bridgeRunning || c.bridgeStarting),
                starting: c.bridgeStarting && c.bridgedServer?.id == s.id,
                onPing: () => c.ping(s),
                onEdit: () => showServerEditor(context, c, existing: s),
                onDelete: () => _confirmDelete(context, s),
                onBridge: () async {
                  await c.startBridge(s);
                  if (c.bridgeRunning) onBridgeStarted();
                },
                onStop: c.stopBridge,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, SavedServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server löschen?'),
        content: Text('„${s.name}“ wird aus der Liste entfernt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) await controller.removeServer(s);
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.status,
    required this.active,
    required this.starting,
    required this.onPing,
    required this.onEdit,
    required this.onDelete,
    required this.onBridge,
    required this.onStop,
  });

  final SavedServer server;
  final ServerStatus? status;
  final bool active;
  final bool starting;
  final VoidCallback onPing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onBridge;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final motd = status?.result?.motd;
    final online = status?.result != null;
    return Card(
      shape: active
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: t.colorScheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(online: online, busy: status?.pinging ?? status == null),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(server.name, style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                      Text(server.endpoint, style: t.textTheme.bodySmall),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => switch (v) {
                    'ping' => onPing(),
                    'edit' => onEdit(),
                    'delete' => onDelete(),
                    _ => null,
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'ping', child: Text('Neu pingen')),
                    PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                    PopupMenuItem(value: 'delete', child: Text('Löschen')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (motd != null) ...[
              Text(motd.plainName, style: t.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                InfoChip(icon: Icons.people_outline, text: '${motd.players}/${motd.maxPlayers}'),
                InfoChip(icon: Icons.sell_outlined, text: motd.version),
                InfoChip(icon: Icons.speed, text: '${status!.result!.latency.inMilliseconds} ms'),
                if (motd.gameMode.isNotEmpty) InfoChip(icon: Icons.landscape_outlined, text: motd.gameMode),
              ]),
            ] else if (status?.error != null)
              Text(status!.error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: active && !starting
                    ? OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.stop), label: const Text('Bridge stoppen'))
                    : FilledButton.icon(
                        onPressed: starting ? null : onBridge,
                        icon: starting
                            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('Ins LAN bringen'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showServerEditor(
  BuildContext context,
  AppController c, {
  SavedServer? existing,
  String? host,
  int? port,
  String? name,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ServerEditor(controller: c, existing: existing, host: host, port: port, name: name),
  );
}

class _ServerEditor extends StatefulWidget {
  const _ServerEditor({required this.controller, this.existing, this.host, this.port, this.name});

  final AppController controller;
  final SavedServer? existing;
  final String? host;
  final int? port;
  final String? name;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? widget.name ?? '');
  late final _host = TextEditingController(text: widget.existing?.host ?? widget.host ?? '');
  late final _port = TextEditingController(text: '${widget.existing?.port ?? widget.port ?? 19132}');
  late final _lanName = TextEditingController(text: widget.existing?.lanName ?? '');
  late bool _relay = widget.existing?.relay ?? false;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _lanName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final c = widget.controller;
    final port = int.parse(_port.text.trim());
    final e = widget.existing;
    if (e == null) {
      await c.addServer(name: _name.text, host: _host.text, port: port, lanName: _lanName.text, relay: _relay);
    } else {
      await c.updateServer(e.copyWith(
        name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
        host: _host.text.trim(),
        port: port,
        lanName: _lanName.text.trim(),
        relay: _relay,
      ));
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'Server hinzufügen' : 'Server bearbeiten',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'Adresse', hintText: 'play.example.net oder 203.0.113.5'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: validateHost,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port (UDP)'),
              keyboardType: TextInputType.number,
              validator: validatePort,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name in der App (optional)'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _lanName,
              decoration: const InputDecoration(
                labelText: 'Name im LAN-Tab (optional)',
                helperText: 'Leer lassen, um die Server-MOTD anzuzeigen',
              ),
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _relay,
              onChanged: (v) => setState(() => _relay = v),
              title: const Text('Dauerhaft über dieses Handy leiten'),
              subtitle: const Text(
                'Nur nötig, wenn der Server Weiterleitungen ablehnt. Dann muss die App '
                'während des ganzen Spiels offen bleiben.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _submit, child: const Text('Speichern')),
          ],
        ),
      ),
    );
  }
}
