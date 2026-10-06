import 'package:flutter/widgets.dart';

/// True while keyboard focus sits in a text field. The focused node's
/// context belongs to the `Focus` that `EditableText` builds, so look for
/// an `EditableText` above it (walking FocusNode parents never meets one).
bool textInputFocused([FocusNode? node]) {
  final n = node ?? FocusManager.instance.primaryFocus;
  return n?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
}
