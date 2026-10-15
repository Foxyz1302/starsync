import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../desktop_entry.dart' show appId;
import '../ports/system_notifications.dart';

/// [SystemNotifications] on the desktop, through flutter_local_notifications'
/// platform plugins (used directly, not through its facade, so the platform
/// is picked by the OS and not by Flutter's target platform):
/// - Linux: `org.freedesktop.Notifications` over D-Bus (pure Dart), with the
///   app's icon (the bundled PNG, else the launcher entry's icon by name);
///   a click is the notification's default action.
/// - Windows: toast notifications (WinRT), the app's name and icon, a click
///   activates the app while it runs (an unpackaged app has no history).
/// Silent: the app plays its own sound for the same notice. Anything that
/// fails (no notification daemon, no session bus) is logged and dropped.
class DesktopNotifications implements SystemNotifications {
  DesktopNotifications({this.appName = 'Starsync'});

  final String appName;
  void Function(String payload)? _onClick;
  Future<bool>? _ready;
  LinuxFlutterLocalNotificationsPlugin? _linux;
  FlutterLocalNotificationsWindows? _windows;
  // Tag -> id, so a notification with the same tag replaces the last one.
  final _ids = <String, int>{};
  int _next = 1;

  @override
  set onClick(void Function(String payload)? handler) => _onClick = handler;

  void _clicked(NotificationResponse r) => _onClick?.call(r.payload ?? '');

  /// The bundled 256 px icon next to the executable (a release or a
  /// `flutter run` build), else the icon the launcher entry installed.
  static LinuxNotificationIcon _linuxIcon() {
    final exe = File(Platform.resolvedExecutable).parent.path;
    final png = File('$exe/data/flutter_assets/assets/icon/icon_256.png');
    return png.existsSync() ? FilePathLinuxIcon(png.path) : ThemeLinuxIcon(appId);
  }

  Future<bool> _init() => _ready ??= () async {
        try {
          if (Platform.isLinux) {
            final p = _linux = LinuxFlutterLocalNotificationsPlugin();
            return await p.initialize(
                  settings: LinuxInitializationSettings(defaultActionName: 'Open', defaultIcon: _linuxIcon()),
                  onDidReceiveNotificationResponse: _clicked,
                ) ??
                false;
          }
          if (Platform.isWindows) {
            final exe = File(Platform.resolvedExecutable).parent.path;
            final icon = File('$exe/data/flutter_assets/assets/icon/icon_256.png');
            final p = _windows = FlutterLocalNotificationsWindows();
            return await p.initialize(
              settings: WindowsInitializationSettings(
                appName: appName,
                appUserModelId: 'Foxyz.Starsync',
                guid: '6c0f4b4e-3e8a-4b8e-9d0c-5a7f2b1e9c31',
                iconPath: icon.existsSync() ? icon.path : null,
              ),
              onDidReceiveNotificationResponse: _clicked,
            );
          }
        } catch (e) {
          debugPrint('system notifications unavailable: $e');
        }
        return false;
      }();

  @override
  Future<void> show({required String title, required String body, String tag = '', String payload = ''}) async {
    if (!await _init()) return;
    final id = tag.isEmpty ? _next++ : _ids[tag] ??= _next++;
    try {
      if (_linux case final p?) {
        await p.show(
          id: id,
          title: title,
          body: body,
          payload: payload,
          notificationDetails: const LinuxNotificationDetails(suppressSound: true),
        );
      } else if (_windows case final p?) {
        await p.show(
          id: id,
          title: title,
          body: body,
          payload: payload,
          notificationDetails: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
        );
      }
    } catch (e) {
      debugPrint('system notification failed: $e');
    }
  }
}
