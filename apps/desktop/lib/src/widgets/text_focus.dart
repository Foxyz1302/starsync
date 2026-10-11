import 'package:flutter/widgets.dart';

/// True while keyboard focus sits in a text field, or anywhere under a
/// [KeyboardClaim]. The focused node's context belongs to the `Focus` that
/// `EditableText` builds, so look for an `EditableText` above it (walking
/// FocusNode parents never meets one).
bool textInputFocused([FocusNode? node]) {
  final c = (node ?? FocusManager.instance.primaryFocus)?.context;
  if (c == null) return false;
  return c.findAncestorWidgetOfExactType<EditableText>() != null ||
      c.findAncestorWidgetOfExactType<KeyboardClaim>() != null;
}

/// Keyboard focus under it counts as typing ([textInputFocused]): a panel
/// with keys of its own (the Up next popover's Ctrl+V) keeps the app's
/// global keys (Space, Tab, the player's) off while it has focus, as a
/// text field does.
class KeyboardClaim extends StatelessWidget {
  final Widget child;
  const KeyboardClaim({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
