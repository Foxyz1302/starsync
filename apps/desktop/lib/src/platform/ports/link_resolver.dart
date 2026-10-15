import 'package:sync_relay_core/core.dart' show LinkProbe, YtDlp;

/// Web page links: what they are and how they play, through the app's
/// yt-dlp (a process on desktop).
abstract interface class LinkResolver {
  /// The yt-dlp behind it (relaying a link, cookies, the hosted server's
  /// shared folder).
  Future<YtDlp> get ytDlp;

  /// Gets it ready in the background (download on first run, updates).
  void warmUp();

  /// mpv's `ytdl-raw-options` (sub languages, cookies).
  Future<String> mpvRawOptions();

  /// What [url] is, remembered for a while ([keep]); [fresh] asks again.
  Future<LinkProbe> probe(String url, {Duration keep, bool fresh});

  /// [url] no longer needs keeping longer than usual.
  void release(String url);
}
