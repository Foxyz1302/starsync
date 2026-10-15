import 'folder_access.dart';
import 'link_resolver.dart';
import 'player_host.dart';
import 'shell_port.dart';
import 'system_notifications.dart';
import 'url_opener.dart';

export 'app_dirs.dart';
export 'folder_access.dart';
export 'link_resolver.dart';
export 'player_host.dart';
export 'shell_port.dart';
export 'system_notifications.dart';
export 'url_opener.dart';

/// The platform as the app sees it: one set, made in the composition
/// root ([AppGraph]) and handed on from there.
class Ports {
  final ShellPort shell;
  final UrlOpener urls;
  final FolderAccess folders;
  final LinkResolver links;
  final SystemNotifications notifications;
  /// The media players (mpv): created, rendered and disposed here.
  final PlayerHost players;
  const Ports({
    required this.shell,
    required this.urls,
    required this.folders,
    required this.links,
    required this.notifications,
    required this.players,
  });
}
