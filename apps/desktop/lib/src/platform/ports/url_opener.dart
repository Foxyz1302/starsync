/// Opens links outside the app.
abstract interface class UrlOpener {
  /// Opens [url] with the system's handler (a browser for web links, the
  /// file manager for a `file:` folder); false when nothing opened it.
  Future<bool> open(String url);
}
