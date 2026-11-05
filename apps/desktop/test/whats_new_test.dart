import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/screens/home/update_indicator.dart';
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/update/whats_new.dart';
import 'package:starsync/src/widgets/whats_new_card.dart';

const _changes = ReleaseChanges(
  added: ['Danmaku style notifications', 'Bilibili style chat box'],
  changed: ['A cleaner mini player'],
  fixed: ['Optimized relay', 'Various bug fixes'],
);

const _highlights = ['Danmaku over the video', 'Chat in the player'];

UpdateManifest _manifest({
  String version = '1.3.3',
  ReleaseChanges? changes = _changes,
  String notes = 'Chat, relay',
  List<String> highlights = const [],
}) => UpdateManifest(
  version: version,
  protocol: 1,
  url: 'http://x/a.tgz',
  notes: notes,
  changes: changes,
  highlights: highlights,
);

UpdateController _controller({String current = '1.3.2'}) => UpdateController(
    currentVersion: current,
    executablePath: '/nowhere/starsync',
    restart: (_, _) async {},
    beforeRestart: (_) async {});

Widget _app(Widget child) => MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  group('card', () {
    testWidgets('highlights first; All changes unfolds the sections in place', (tester) async {
      await tester.pumpWidget(_app(const Center(
          child: WhatsNewCard(
              notes: ReleaseNotes(version: '1.3.3', notes: 'Chat, relay', changes: _changes, highlights: _highlights)))));
      await tester.pumpAndSettle();
      for (final h in _highlights) {
        expect(find.text(h), findsOneWidget);
      }
      expect(find.text('Chat, relay'), findsNothing, reason: 'the highlights say it');
      expect(find.text('Optimized relay'), findsNothing);
      for (final k in ChangeKind.values) {
        expect(find.byKey(ValueKey('whats-new-${k.name}')), findsNothing);
      }
      expect(find.text('All changes (5)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whats-new-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-all')), findsNothing);
      for (final item in [..._highlights, ..._changes.fixed, ..._changes.added]) {
        expect(find.text(item), findsOneWidget);
      }
      expect(tester.getTopLeft(find.text(_highlights.first)).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('whats-new-added'))).dy));
    });

    testWidgets('no highlights, a few items: the whole list at once', (tester) async {
      const few = ReleaseChanges(added: ['One'], fixed: ['Two', 'Three']);
      await tester.pumpWidget(_app(const Center(child: WhatsNewCard(notes: ReleaseNotes(version: '1.3.3', changes: few)))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-all')), findsNothing);
      expect(find.byKey(const ValueKey('whats-new-fixed')), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
    });

    testWidgets('no highlights, many items (an older version): the first few, then All changes', (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () => showWhatsNew(
              context, const ReleaseNotes(version: '1.3.3', notes: 'Chat, relay', changes: _changes)),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-card')), findsOneWidget);
      expect(find.text("What's new in 1.3.3"), findsOneWidget);
      expect(find.text('Chat, relay'), findsOneWidget);
      expect(find.text(_changes.added.first), findsOneWidget);
      expect(find.text(_changes.fixed.last), findsNothing, reason: 'past the first $whatsNewFirstItems');
      await tester.tap(find.byKey(const ValueKey('whats-new-all')));
      await tester.pumpAndSettle();
      final heads = [for (final k in ChangeKind.values) tester.getTopLeft(find.byKey(ValueKey('whats-new-${k.name}'))).dy];
      expect(heads, orderedEquals([...heads]..sort()), reason: 'Added, Changed, Fixed');
      for (final item in [..._changes.added, ..._changes.changed, ..._changes.fixed]) {
        expect(find.text(item), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('whats-new-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-card')), findsNothing);
    });

    testWidgets('notes only (a manifest from before the changelog): one paragraph, no sections', (tester) async {
      await tester.pumpWidget(_app(const Center(
          child: WhatsNewCard(notes: ReleaseNotes(version: '1.3.2', notes: 'Fixes Windows closing by itself.')))));
      await tester.pumpAndSettle();
      expect(find.text('Fixes Windows closing by itself.'), findsOneWidget);
      for (final k in ChangeKind.values) {
        expect(find.byKey(ValueKey('whats-new-${k.name}')), findsNothing);
      }
    });

    testWidgets('a long list scrolls inside a short window, no overflow', (tester) async {
      tester.view.physicalSize = const Size(800, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final many = ReleaseChanges(fixed: [for (var i = 0; i < 40; i++) 'Fix number $i']);
      await tester.pumpWidget(_app(Center(child: WhatsNewCard(notes: ReleaseNotes(version: '2.0.0', changes: many)))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('whats-new-all')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('whats-new-card'))).height, lessThanOrEqualTo(420 - 64));
      await tester.drag(find.byKey(const ValueKey('whats-new-list')), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('Fix number 39'), findsOneWidget);
    });
  });

  group('band', () {
    Future<UpdateController> pump(WidgetTester tester, UpdateManifest m) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      c.status.value = UpdateStatus(UpdatePhase.available, manifest: m, canInstall: true);
      await tester.pumpWidget(_app(Column(children: [UpdateBar(controller: c)])));
      return c;
    }

    testWidgets('with changes: the first items, What\'s new opens the card with Update and restart', (tester) async {
      await pump(tester, _manifest());
      final preview = tester.widget<Text>(find.byKey(const ValueKey('whats-new-preview'))).textSpan!.toPlainText();
      expect(preview, contains('You are running 1.3.2'));
      expect(preview, contains('Danmaku style notifications'));
      expect(preview, contains('A cleaner mini player'));
      expect(preview, isNot(contains('Optimized relay')), reason: 'three at most');
      expect(find.text('You are running 1.3.2 · Chat, relay'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('update-whats-new')));
      await tester.pumpAndSettle();
      expect(find.text("What's new in 1.3.3"), findsOneWidget);
      expect(find.text('Danmaku style notifications'), findsOneWidget);
      expect(find.byKey(const ValueKey('whats-new-install')), findsOneWidget);
    });

    testWidgets('with highlights: the band shows them, the card opens on them', (tester) async {
      await pump(tester, _manifest(highlights: _highlights));
      final preview = tester.widget<Text>(find.byKey(const ValueKey('whats-new-preview'))).textSpan!.toPlainText();
      expect(preview, contains('Danmaku over the video'));
      expect(preview, isNot(contains('Danmaku style notifications')));
      await tester.tap(find.byKey(const ValueKey('update-whats-new')));
      await tester.pumpAndSettle();
      expect(find.text('Danmaku over the video'), findsOneWidget);
      expect(find.byKey(const ValueKey('whats-new-all')), findsOneWidget);
    });

    testWidgets('without changes (old manifest): the notes line, What\'s new shows them', (tester) async {
      await pump(tester, _manifest(changes: null));
      expect(find.byKey(const ValueKey('whats-new-preview')), findsNothing);
      expect(find.text('You are running 1.3.2 · Chat, relay'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-whats-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-card')), findsOneWidget);
      expect(find.text('Chat, relay'), findsWidgets);
    });

    testWidgets('nothing to tell: no What\'s new button', (tester) async {
      await pump(tester, _manifest(changes: null, notes: ''));
      expect(find.byKey(const ValueKey('update-whats-new')), findsNothing);
      expect(find.byKey(const ValueKey('update-install')), findsOneWidget);
    });
  });

  group('show once', () {
    test('after an install: due at the first start, never again once shown', () async {
      final store = MemoryWhatsNewStore(seen: '1.3.2');
      // The old version keeps the new one's notes before restarting.
      await WhatsNew(currentVersion: '1.3.2', store: store).installing(_manifest());
      expect(store.notes!.version, '1.3.3');

      final first = WhatsNew(currentVersion: '1.3.3', store: store)..start(_controller(current: '1.3.3'));
      expect(first.due.value?.version, '1.3.3');
      expect(first.due.value?.changes?.fixed, _changes.fixed);
      first.shown();
      expect(first.due.value, isNull);
      expect(store.seen, '1.3.3');

      final second = WhatsNew(currentVersion: '1.3.3', store: store)..start(_controller(current: '1.3.3'));
      expect(second.due.value, isNull);
      expect(second.current?.version, '1.3.3', reason: 'About still opens it');
    });

    test('updated another way (1.3.x updater): the first check reading this version brings it', () {
      final store = MemoryWhatsNewStore();
      final c = _controller(current: '1.3.3');
      final w = WhatsNew(currentVersion: '1.3.3', store: store)..start(c);
      expect(w.due.value, isNull);
      c.latest.value = _manifest(version: '1.3.4');
      expect(w.due.value, isNull, reason: 'another version');
      c.latest.value = _manifest();
      expect(w.due.value?.version, '1.3.3');
      expect(store.notes?.version, '1.3.3');
    });

    test('a fresh install shows nothing, but About has the notes once known', () {
      final store = MemoryWhatsNewStore(fresh: true);
      final c = _controller(current: '1.3.3');
      final w = WhatsNew(currentVersion: '1.3.3', store: store)..start(c);
      expect(store.seen, '1.3.3');
      c.latest.value = _manifest();
      expect(w.due.value, isNull);
      expect(w.current?.version, '1.3.3');
    });

    test('notes of another version or empty notes are never due', () {
      final store = MemoryWhatsNewStore(
          seen: '1.3.2', notes: const ReleaseNotes(version: '1.3.4', changes: _changes));
      expect((WhatsNew(currentVersion: '1.3.3', store: store)..start(_controller())).due.value, isNull);
      final empty = MemoryWhatsNewStore(seen: '1.3.2', notes: const ReleaseNotes(version: '1.3.3'));
      expect((WhatsNew(currentVersion: '1.3.3', store: empty)..start(_controller())).due.value, isNull);
    });

    test('kept notes survive a round trip through settings JSON', () {
      final n = ReleaseNotes.of(_manifest(highlights: _highlights));
      final back = ReleaseNotes.fromJson(n.toJson())!;
      expect(back.version, '1.3.3');
      expect(back.notes, 'Chat, relay');
      expect(back.changes!.toJson(), _changes.toJson());
      expect(back.highlights, _highlights);
      expect(ReleaseNotes.fromJson(ReleaseNotes.of(_manifest()).toJson())!.highlights, isEmpty);
      expect(ReleaseNotes.fromJson({'notes': 'no version'}), isNull);
      expect(ReleaseNotes.fromJson('junk'), isNull);
    });
  });
}
