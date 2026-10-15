/// Notifications outside the window (the desktop's notification center,
/// Android's shade). The policy that uses them comes with the Notifier.
abstract interface class SystemNotifications {
  /// Shows [title] / [body]; replaces the one with the same [tag].
  Future<void> show({required String title, required String body, String tag = ''});
}

/// Shows nothing (desktop today).
class NoSystemNotifications implements SystemNotifications {
  const NoSystemNotifications();

  @override
  Future<void> show({required String title, required String body, String tag = ''}) async {}
}
