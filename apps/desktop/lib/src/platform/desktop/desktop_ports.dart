import '../../playback/yt_dlp_app.dart';
import '../ports/ports.dart';
import 'desktop_folders.dart';
import 'desktop_shell.dart';
import 'desktop_urls.dart';

/// The desktop's [Ports].
Ports desktopPorts() {
  const urls = DesktopUrls();
  return Ports(
    shell: DesktopShell(),
    urls: urls,
    folders: const DesktopFolders(urls),
    links: AppYtDlp.instance,
    notifications: const NoSystemNotifications(),
  );
}
