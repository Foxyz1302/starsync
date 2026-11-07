import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:starsync/src/files/scanner.dart' show FolderScan;
import 'package:starsync/src/platform/ports/folder_access.dart';
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/picture_picker.dart';
import 'package:starsync/src/shell/profile_edit.dart';

import 'test_graph.dart';

/// Records file chooser calls; [next] answers the next one.
class _Folders implements FolderAccess {
  final picks = <List<String>>[];
  Completer<List<String>>? next;
  @override
  Future<List<String>> pickFiles({required String dialogTitle, required List<String> extensions}) {
    picks.add(extensions);
    return (next ??= Completer()).future;
  }

  @override
  Future<String?> pickFolder({required String dialogTitle}) async => null;
  @override
  Future<FolderScan> scan(String dir) => throw UnimplementedError();
  @override
  bool folderExists(String dir) => false;
  @override
  Future<FileStat> stat(String path) => throw UnimplementedError();
  @override
  Future<bool> reveal(String dir) async => false;
  @override
  Future<String> screenshotFolder() async => '';
}

/// Drops land through [drop].
class _Shell extends FakeShell {
  void Function(List<String> paths, Offset at)? drop;
  @override
  Widget dropTarget({
    Key? key,
    bool enable = true,
    VoidCallback? onEnter,
    VoidCallback? onExit,
    required void Function(List<String> paths, Offset at) onDrop,
    required Widget child,
  }) {
    drop = onDrop;
    return KeyedSubtree(key: key, child: child);
  }
}

final _folders = _Folders();
final _shell = _Shell();
final _graph = testGraph(shell: _shell, folders: _folders);

Uint8List _png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

void main() {
  setUp(() {
    _folders.picks.clear();
    _folders.next = null;
    _shell.clipboardImage = null;
    _graph.coordinator.settings.avatarCircle.value = false;
  });

  Future<List<Uint8List>> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final used = <Uint8List>[];
    await tester.pumpWidget(
      scoped(
        _graph,
        MaterialApp(
          home: Scaffold(
            body: Center(child: CropPicker(onUse: (png) async => used.add(png))),
          ),
        ),
      ),
    );
    await tester.pump();
    return used;
  }

  /// [work] with real async (image decoding), then a frame.
  Future<void> real(WidgetTester tester, Future<void> Function() work) async {
    await tester.runAsync(() async {
      await work();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('a click on your picture opens the app\'s picker only, never the file chooser', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      scoped(
        _graph,
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ProfilePicture(
                profile: _graph.profile,
                info: const AvatarInfo(name: 'Alex', color: Colors.teal),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('profile-picture-add')),
      findsOneWidget,
      reason: 'without a picture, the badge says one can be added',
    );
    await tester.tap(find.byKey(const ValueKey('profile-picture')));
    await tester.pumpAndSettle();
    expect(find.text('Paste a picture (Ctrl+V) or drop one here'), findsOneWidget);
    expect(find.byKey(const ValueKey('picture-paste')), findsOneWidget);
    expect(find.byKey(const ValueKey('picture-browse')), findsOneWidget);
    expect(_folders.picks, isEmpty);
  });

  testWidgets('Ctrl+V pastes the clipboard\'s picture; none says so', (tester) async {
    final used = await pumpPicker(tester);
    await real(
      tester,
      () => tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft).then((_) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }),
    );
    expect(find.byKey(const ValueKey('picture-error')), findsOneWidget);
    _shell.clipboardImage = _png(64, 32);
    await real(tester, () => tester.tap(find.byKey(const ValueKey('picture-paste'))));
    expect(find.text('Drag to move · scroll to zoom'), findsOneWidget);
    expect(find.byKey(const ValueKey('picture-error')), findsNothing);
    await real(tester, () => tester.tap(find.byKey(const ValueKey('picture-use'))));
    expect(used, hasLength(1));
  });

  testWidgets('Browse… opens the file chooser only when clicked, and says so meanwhile', (tester) async {
    await pumpPicker(tester);
    expect(_folders.picks, isEmpty);
    await tester.tap(find.byKey(const ValueKey('picture-browse')));
    await tester.pump();
    expect(_folders.picks, [pictureExtensions]);
    expect(find.text('Choosing…'), findsOneWidget);
    _folders.next!.complete(const []);
    await tester.pump();
    await tester.pump();
    expect(find.text('Browse…'), findsOneWidget);
    expect(find.text('Drag to move · scroll to zoom'), findsNothing, reason: 'cancelled: nothing picked');
  });

  testWidgets('a dropped picture loads; anything else is refused', (tester) async {
    await pumpPicker(tester);
    _shell.drop!(['/tmp/notes.txt'], Offset.zero);
    await tester.pump();
    expect(find.byKey(const ValueKey('picture-error')), findsOneWidget);
    final dir = Directory.systemTemp.createTempSync('picker_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/me.PNG')..writeAsBytesSync(_png(40, 40));
    await real(tester, () async => _shell.drop!([file.path], Offset.zero));
    expect(find.text('Drag to move · scroll to zoom'), findsOneWidget);
  });

  testWidgets('the crop follows the avatar shape: rounded square, or a circle', (tester) async {
    double radius() {
      final box = tester.widget<AnimatedContainer>(find.byKey(const ValueKey('picture-drop')));
      return ((box.decoration! as BoxDecoration).borderRadius! as BorderRadius).topLeft.x;
    }

    await pumpPicker(tester);
    expect(radius(), closeTo(300 * const AvatarShape().corner, 0.01));
    _graph.coordinator.settings.avatarCircle.value = true;
    await tester.pumpAndSettle();
    expect(radius(), 150);
  });

  test('pictures by extension', () {
    expect(isPicturePath('/a/b.JPG'), isTrue);
    expect(isPicturePath('/a/b.webp'), isTrue);
    expect(isPicturePath('/a/b.mkv'), isFalse);
    expect(isPicturePath('/a/b'), isFalse);
  });
}
