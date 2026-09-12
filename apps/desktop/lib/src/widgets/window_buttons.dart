import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../state/session_state.dart';

class WindowButtons extends StatefulWidget {
  final FocusNode? focusNode;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  const WindowButtons({
    super.key,
    this.focusNode,
    this.fullscreen = false,
    this.onToggleFullscreen,
  });

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  Future<void> _toggleMaximize() async {
    if (widget.onToggleFullscreen != null) {
      widget.onToggleFullscreen!();
      return;
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _close() async {
    try {
      await SessionState.instance.coordinator.leave();
      await SessionState.instance.stopServer();
    } catch (_) {}
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final focus = widget.focusNode;
    final restored = widget.fullscreen || _maximized;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinBtn(
          icon: Icons.remove,
          tooltip: 'Minimize',
          focusNode: focus,
          onPressed: () => windowManager.minimize(),
        ),
        _WinBtn(
          icon: restored ? Icons.filter_none : Icons.crop_square,
          tooltip: restored ? 'Restore' : 'Maximize',
          focusNode: focus,
          onPressed: _toggleMaximize,
        ),
        _WinBtn(
          icon: Icons.close,
          tooltip: 'Close',
          focusNode: focus,
          hoverColor: Colors.red,
          onPressed: _close,
        ),
      ],
    );
  }
}

class _WinBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final Color? hoverColor;
  const _WinBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.focusNode,
    this.hoverColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        focusNode: focusNode,
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
