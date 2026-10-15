import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../session/notifier.dart' show AppEvent, Copied, CopyFailed, noticeFor;
import '../app/app_graph.dart';

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

void Function(AppEvent event) _notifier(BuildContext context) {
  final debug = debugReuseToast;
  if (debug != null) return (event) => debug(noticeFor(event).toast ?? '');
  return AppScope.of(context).notifier.notify;
}

/// Puts [text] on the clipboard and confirms it with a toast ([done]:
/// its text, e.g. "Link copied").
Future<void> copyToClipboard(BuildContext context, String text, {String done = 'Copied'}) async {
  final notify = _notifier(context);
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    notify(const CopyFailed());
    return;
  }
  notify(Copied(done));
}

/// Opens [url] in the browser; when none opens, copies it instead and
/// says so.
Future<void> openLink(BuildContext context, String url) async {
  final urls = AppScope.of(context).ports.urls;
  final notify = _notifier(context);
  if (await urls.open(url)) return;
  try {
    await Clipboard.setData(ClipboardData(text: url));
  } catch (_) {
    notify(const CopyFailed());
    return;
  }
  notify(const Copied("Couldn't open a browser — link copied"));
}
