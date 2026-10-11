import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/session_state.dart';

// Reusing what the app shows elsewhere: copying a link or a title, opening
// a page in the browser. One wording and one confirmation (a small toast)
// for every menu that offers them.

/// The labels of the reuse actions, the same in every menu.
abstract final class ReuseText {
  static const copyLink = 'Copy link';
  static const copyTitle = 'Copy title';
  static const copyMessage = 'Copy message';
  static const openInBrowser = 'Open in browser';
  static const openInJellyfin = 'Open in Jellyfin';
}

/// Tests: where the confirmation goes instead of the session's toasts.
@visibleForTesting
void Function(String text)? debugReuseToast;

void _toast(String text) {
  final debug = debugReuseToast;
  if (debug != null) return debug(text);
  SessionState.instance.coordinator.showToast(text);
}

/// Opens [url] in the default browser (no url_launcher dependency); false
/// when no browser could be started.
Future<bool> openInBrowser(String url) async {
  try {
    final ProcessResult r;
    if (Platform.isWindows) {
      r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      r = await Process.run('open', [url]);
    } else {
      r = await Process.run('xdg-open', [url]);
    }
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Puts [text] on the clipboard and confirms it with a toast ([done]:
/// its text, e.g. "Link copied").
Future<void> copyToClipboard(String text, {String done = 'Copied'}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    _toast("Couldn't copy");
    return;
  }
  _toast(done);
}

/// Opens [url] in the browser; when none opens, copies it instead and
/// says so.
Future<void> openLink(String url) async {
  if (await openInBrowser(url)) return;
  await copyToClipboard(url, done: "Couldn't open a browser — link copied");
}
