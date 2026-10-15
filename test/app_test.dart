// Real pings run in the background here, so progress spinners never
// settle; pump fixed durations instead of pumpAndSettle.
import 'package:bedrockbridge/main.dart';
import 'package:bedrockbridge/src/app/controller.dart';
import 'package:bedrockbridge/src/app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  group('SavedServer', () {
    test('JSON round trip', () {
      final list = [
        SavedServer(id: 'a', name: 'Eins', host: 'example.net', port: 19133, lanName: 'Bei uns', relay: true),
        SavedServer(id: 'b', name: 'Zwei', host: '2001:db8::1'),
      ];
      final back = SavedServer.decodeList(SavedServer.encodeList(list));
      expect(back.map((s) => s.toJson()), list.map((s) => s.toJson()));
    });

    test('input validation', () {
      expect(validateHost('play.example.net'), isNull);
      expect(validateHost('203.0.113.5'), isNull);
      expect(validateHost('2001:db8::1'), isNull);
      expect(validateHost(''), isNotNull);
      expect(validateHost('host:19132'), isNotNull);
      expect(validateHost('a b'), isNotNull);
      expect(validatePort('19132'), isNull);
      expect(validatePort('0'), isNotNull);
      expect(validatePort('70000'), isNotNull);
      expect(validatePort('x'), isNotNull);
    });
  });

  test('controller presets stalincraft.de and persists changes', () async {
    final c = AppController();
    await c.load();
    expect(c.servers.single.host, 'stalincraft.de');
    await c.addServer(name: '', host: 'example.net', port: 19132);
    final again = AppController();
    await again.load();
    expect(again.servers.map((s) => s.host), ['stalincraft.de', 'example.net']);
    expect(again.servers.last.name, 'example.net', reason: 'empty name falls back to host');
    await again.removeServer(again.servers.first);
    final third = AppController();
    await third.load();
    expect(third.servers.single.host, 'example.net');
  });

  testWidgets('app shows saved servers and switches tabs', (tester) async {
    final c = AppController();
    await tester.runAsync(c.load);
    await tester.pumpWidget(BedrockBridgeApp(controller: c));
    await tester.pump();
    expect(find.text('BedrockBridge'), findsOneWidget);
    expect(find.text('stalincraft.de'), findsWidgets);
    expect(find.text('Ins LAN bringen'), findsOneWidget);

    await tester.tap(find.text('LAN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('LAN durchsuchen'), findsOneWidget);

    await tester.tap(find.text('Bridge'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Keine Bridge aktiv'), findsOneWidget);
  });

  testWidgets('add-server form validates input', (tester) async {
    // Phone-sized screen so the whole bottom sheet is on screen.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = AppController();
    await tester.runAsync(c.load);
    await tester.pumpWidget(BedrockBridgeApp(controller: c));
    await tester.tap(find.byType(FloatingActionButton).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Adresse fehlt'), findsOneWidget);
  });
}
