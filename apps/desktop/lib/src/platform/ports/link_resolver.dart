import 'package:sync_relay_core/core.dart' show LinkProbe, YtDlp;

/// Web page links: what they are and how they play, through the app's
/// yt-dlp (a process on desktop).
abstract interface class LinkResolver {
  /// The yt-dlp behind it (relaying a link, cookies, the hosted server's
  /// shared folder).
  Future<YtDlp> get ytDlp;

  /// Gets it ready in the background (download on first run, updates).
  void warmUp();

  /// This device opens web pages itself (the media plan's `resolve`
  /// capability). Desktop: always (yt-dlp is downloaded when first
  /// needed); a device without it gets pages passed on by someone else.
  bool get resolvesLinks;

  /// What [url] is, remembered for a while ([keep]); [fresh] asks again.
  Future<LinkProbe> probe(String url, {Duration keep, bool fresh});

  /// [url] no longer needs keeping longer than usual.
  void release(String url);
}
