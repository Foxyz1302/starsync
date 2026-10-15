/// Notifications outside the window (the desktop's notification center,
/// Android's shade). The Notifier decides what goes out here (see
/// `noticeFor`); the port only shows them and reports clicks.
abstract interface class SystemNotifications {
  /// Shows [title] / [body] with the app's name and icon; one with the
  /// same [tag] replaces it. [payload] comes back to [onClick].
  Future<void> show({required String title, required String body, String tag = '', String payload = ''});

  /// Called with a notification's payload when the user clicks it (set
  /// once, by the Notifier).
  set onClick(void Function(String payload)? handler);
}

/// Shows nothing (tests, platforms without one).
class NoSystemNotifications implements SystemNotifications {
  const NoSystemNotifications();

  @override
  Future<void> show({required String title, required String body, String tag = '', String payload = ''}) async {}

  @override
  set onClick(void Function(String payload)? handler) {}
}
