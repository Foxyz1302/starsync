import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../session/notifier.dart' show AppEvent, Copied, CopyFailed, noticeFor;
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

void _notify(AppEvent event) {
  final debug = debugReuseToast;
  if (debug != null) return debug(noticeFor(event).toast ?? '');
  SessionState.instance.coordinator.notify(event);
}

/// Puts [text] on the clipboard and confirms it with a toast ([done]:
/// its text, e.g. "Link copied").
Future<void> copyToClipboard(String text, {String done = 'Copied'}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    _notify(const CopyFailed());
    return;
  }
  _notify(Copied(done));
}

/// Opens [url] in the browser; when none opens, copies it instead and
/// says so.
Future<void> openLink(String url) async {
  if (await SessionState.instance.ports.urls.open(url)) return;
  await copyToClipboard(url, done: "Couldn't open a browser — link copied");
}
