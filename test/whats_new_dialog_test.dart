import 'dart:io';

import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/features/shell/whats_new_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/changelog_markdown.dart';

/// The What's new popup fits any screen: the list scrolls inside it, and
/// the header and OK always stay on screen.
void main() {
  // Real notes: the longest release in CHANGELOG.md (what's under Unreleased
  // changes with every commit, so the test doesn't depend on it).
  final releases = ChangelogMarkdown.parse(File('CHANGELOG.md').readAsStringSync())
    ..sort((a, b) => b.sections.expand((s) => s.items).length.compareTo(a.sections.expand((s) => s.items).length));
  final longest = releases.first;

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showWhatsNew(context, longest),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('small phone', const Size(320, 568)),
    ('landscape phone', const Size(844, 390)),
    ('desktop', const Size(1280, 800)),
  ]) {
    testWidgets('fits a $name screen, scrolls, and OK closes it', (tester) async {
      await open(tester, size);
      // One version only, never earlier builds.
      expect(find.text('Version ${longest.version} · Build ${longest.build}'), findsOneWidget);
      for (final other in releases.skip(1)) {
        expect(find.text('Version ${other.version} · Build ${other.build}'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      expect(find.text('What\'s new'), findsOneWidget);

      final ok = find.text('OK');
      expect(ok, findsOneWidget);
      final okBox = tester.getRect(ok);
      expect(okBox.bottom, lessThanOrEqualTo(size.height), reason: 'OK must stay on screen');

      // The list is longer than the space left: it scrolls, the button stays put.
      final scrollable = find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable.first).position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scrollable.first, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(ok), okBox);

      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }
}
