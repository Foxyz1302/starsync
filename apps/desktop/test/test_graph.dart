// Test support (not a test): the app's composition root for tests.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';
import 'package:starsync/src/app/app_graph.dart';
import 'package:starsync/src/platform/desktop/desktop_ports.dart';
import 'package:starsync/src/platform/ports/ports.dart';
import 'package:starsync/src/screens/home/health_probe.dart';
import 'package:starsync/src/session/identity.dart' show ClientIdentity;

/// One graph per test file, like the app's one per run: nothing starts
/// until a test calls `navigation.start()` (or `goHome`), so widget tests
/// see the app before your server is up. Sharing looks up no internet
/// address unless [publicAddress] gives one. [shell] stands in for the
/// window (the desktop's needs window_manager), [links] for yt-dlp,
/// [folders] for the file chooser.
AppGraph testGraph(
        {HealthGetter healthGet = defaultHealthGet,
        Future<String?> Function()? publicAddress,
        ShellPort? shell,
        LinkResolver? links,
        FolderAccess? folders}) =>
    AppGraph.build(
        ports: shell == null && links == null && folders == null ? null : _withStandIns(shell, links, folders),
        identity: ClientIdentity.ephemeral(),
        healthGet: healthGet,
        publicAddress: publicAddress ?? () async => null);

Ports _withStandIns(ShellPort? shell, LinkResolver? links, FolderAccess? folders) {
  final p = desktopPorts();
  return Ports(
      shell: shell ?? p.shell,
      urls: p.urls,
      folders: folders ?? p.folders,
      links: links ?? p.links,
      notifications: p.notifications,
      players: p.players);
}

/// [child] under [graph]'s [AppScope].
Widget scoped(AppGraph graph, Widget child) => AppScope(graph: graph, child: child);

/// A window that records what was asked of it (the window buttons'
/// minimise, maximise, close; fullscreen).
class FakeShell implements ShellPort {
  final calls = <String>[];
  /// What Ctrl+V outside a text field finds.
  Paste paste = (files: const <String>[], text: null);

  @override
  Future<void> start({required String title, required Future<void> Function() onCloseRequest}) async {}
  @override
  Future<void> setFullScreen(bool on) async => calls.add('fullscreen $on');
  @override
  Future<void> minimize() async => calls.add('minimize');
  @override
  Future<bool> isMaximized() async => false;
  @override
  Future<void> maximize() async => calls.add('maximize');
  @override
  Future<void> unmaximize() async => calls.add('unmaximize');
  @override
  void Function() watchMaximized(void Function(bool maximized) onChange) => () {};
  @override
  void Function() watchActivity(void Function(WindowActivity activity) onChange) => () {};
  @override
  Future<void> startDragging() async {}
  @override
  Future<void> requestClose() async => calls.add('close');
  @override
  Future<void> saveWindow() async {}
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  Future<void> quit() async => calls.add('quit');
  @override
  Future<void> focus({String activation = ''}) async {}
  @override
  Future<void> requestAttention() async {}
  @override
  Future<Paste> readPaste() async => paste;
  @override
  Future<String?> readClipboardText() async => null;
  /// What [readImage] finds on the clipboard.
  Uint8List? clipboardImage;
  @override
  Future<Uint8List?> readImage() async => clipboardImage;
  /// The images [copyImage] put on the clipboard.
  final images = <Uint8List>[];
  @override
  Future<bool> copyImage(Uint8List png) async {
    images.add(png);
    return true;
  }
  @override
  Widget dropTarget({
    Key? key,
    bool enable = true,
    VoidCallback? onEnter,
    VoidCallback? onExit,
    required void Function(List<String> paths, Offset at) onDrop,
    required Widget child,
  }) =>
      KeyedSubtree(key: key, child: child);
}
