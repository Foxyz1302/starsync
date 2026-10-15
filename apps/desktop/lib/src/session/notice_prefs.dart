// The user's notification choices (Settings → Notifications & sounds), as
// the Notifier's policy reads them. Pure Dart; [AppSettings] stores them.

/// When chat messages pop up as toasts (they always reach the chat).
enum ChatPopups {
  all('All'),
  paused('Only when paused'),
  off('Off');

  final String label;
  const ChatPopups(this.label);

  /// Whether a chat message pops up now ([playing]: the video plays).
  bool shows({required bool playing}) => switch (this) {
        ChatPopups.all => true,
        ChatPopups.paused => !playing,
        ChatPopups.off => false,
      };
}

/// What the user picked: chat pop-ups, and whether joins and leaves also
/// reach them while they sit out or the window is in the background
/// ([people]; off by default: then only chat, nudges, "starting now" and
/// Up next do).
class NotifyPrefs {
  final ChatPopups chat;
  final bool people;
  const NotifyPrefs({this.chat = ChatPopups.all, this.people = false});
}
