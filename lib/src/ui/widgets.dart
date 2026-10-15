import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// iOS blocks UDP broadcast unless Apple grants the multicast entitlement,
/// which sideloaded builds (AltStore with a free Apple ID) cannot have.
bool get broadcastLimited => !kIsWeb && Platform.isIOS;

const iosBroadcastHint = 'iOS blockiert Broadcasts für Apps aus AltStore. Die LAN-Suche fragt deshalb jedes Gerät '
    'im WLAN einzeln ab. Konsolen sehen eine Bridge auf dem iPhone nicht im LAN-Tab – '
    'dafür die Bridge auf einem Android-Handy im selben WLAN starten.';

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.online, this.busy = false});

  final bool online;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) return const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2));
    return Semantics(
      label: online ? 'online' : 'offline',
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? const Color(0xFF4CAF50) : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: t.textTheme.labelMedium),
      ]),
    );
  }
}

class MessageCard extends StatelessWidget {
  const MessageCard({super.key, required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: error ? cs.errorContainer : cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: error ? cs.onErrorContainer : cs.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: error ? cs.onErrorContainer : cs.onSecondaryContainer)),
          ),
        ]),
      ),
    );
  }
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}
