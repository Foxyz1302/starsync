import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sync_relay_core/core.dart';

/// mpv's `ytdl-format` for links every player opens itself.
const ytdlFormat = 'bv*[height<=1080]+ba/b';

/// The app's yt-dlp (see [YtDlp]): in the app-support folder, shared with
/// the hosted server. [probe] remembers what pasted links are for a while,
/// so the Link preview and the swap ask once.
class AppYtDlp {
  static final instance = AppYtDlp();

  /// [ytDlp]: a given one (tests); default in the app-support folder.
  AppYtDlp([YtDlp? ytDlp]) : _ytDlp = ytDlp == null ? null : Future.value(ytDlp);

  Future<YtDlp>? _ytDlp;
  Future<YtDlp> get ytDlp => _ytDlp ??= () async {
        final base = await getApplicationSupportDirectory();
        return YtDlp(dir(base.path));
      }();

  static String dir(String appSupport) => '$appSupport${Platform.pathSeparator}yt-dlp';

  /// Gets yt-dlp ready in the background (download on first run, a daily
  /// update check afterwards).
  void warmUp() => unawaited(ytDlp.then((y) => y.ensure()).catchError((_) => null));

  final _probes = <String, (DateTime, Future<LinkProbe>)>{};
  static const _probeTtl = Duration(minutes: 10);

  Future<LinkProbe> probe(String url) {
    final now = DateTime.now();
    _probes.removeWhere((_, v) => now.difference(v.$1) > _probeTtl);
    final hit = _probes[url];
    if (hit != null) return hit.$2;
    final f = ytDlp.then((y) => probeLink(Uri.parse(url), ytDlp: y));
    _probes[url] = (now, f);
    f.catchError((Object _) {
      _probes.remove(url);
      return LinkProbe.file(Uri(), -1);
    });
    return f;
  }
}
