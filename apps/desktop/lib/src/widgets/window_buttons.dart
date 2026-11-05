import 'package:flutter/material.dart';

import '../app/app_graph.dart';

/// Minimise, maximise / restore and close. They never take keyboard
/// focus: the arrow keys never land on them and Enter or Space never
/// presses them.
class WindowButtons extends StatefulWidget {
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  const WindowButtons({
    super.key,
    this.fullscreen = false,
    this.onToggleFullscreen,
  });

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  late final _shell = AppScope.of(context).ports.shell;
  bool _maximized = false;
  late final void Function() _stopWatch;

  @override
  void initState() {
    super.initState();
    _stopWatch = _shell.watchMaximized((v) {
      if (mounted) setState(() => _maximized = v);
    });
    _shell.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    _stopWatch();
    super.dispose();
  }

  Future<void> _toggleMaximize() async {
    if (widget.onToggleFullscreen != null) {
      widget.onToggleFullscreen!();
      return;
    }
    if (await _shell.isMaximized()) {
      await _shell.unmaximize();
    } else {
      await _shell.maximize();
    }
  }

  Future<void> _close() async {
    try {
      final graph = AppScope.of(context);
      await graph.navigation.leave();
      await graph.yourServer.stop();
    } catch (_) {}
    await _shell.requestClose();
  }

  @override
  Widget build(BuildContext context) {
    final restored = widget.fullscreen || _maximized;
    return ExcludeFocus(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WinBtn(
            icon: Icons.remove,
            tooltip: 'Minimize',
            onPressed: () => _shell.minimize(),
          ),
          _WinBtn(
            icon: restored ? Icons.filter_none : Icons.crop_square,
            tooltip: restored ? 'Restore' : 'Maximize',
            onPressed: _toggleMaximize,
          ),
          _WinBtn(
            icon: Icons.close,
            tooltip: 'Close',
            hoverColor: Colors.red,
            onPressed: _close,
          ),
        ],
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? hoverColor;
  const _WinBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.hoverColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 40, height: 32),
        iconSize: 15,
        splashRadius: 12,
        hoverColor: (hoverColor ?? Colors.white).withValues(alpha: 0.12),
        highlightColor: Colors.transparent,
        icon: Icon(icon, size: 15),
        onPressed: onPressed,
      ),
    );
  }
}

/// The title area: drag moves the window, a double click maximizes or
/// restores it (window_manager's DragToMoveArea, through [ShellPort]).
class WindowDragArea extends StatelessWidget {
  final Widget child;
  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final shell = AppScope.of(context).ports.shell;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => shell.startDragging(),
      onDoubleTap: () async {
        if (await shell.isMaximized()) {
          await shell.unmaximize();
        } else {
          await shell.maximize();
        }
      },
      child: child,
    );
  }
}
