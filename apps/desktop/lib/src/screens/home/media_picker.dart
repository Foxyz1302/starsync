import 'package:flutter/material.dart';

import '../../jellyfin/browse_scope.dart' show JellyfinSelection;
import '../../widgets/media_input.dart';
import 'picked_media.dart';

export 'picked_media.dart';

/// The Library's sources.
enum MediaKind { jellyfin, link, file }

/// State of the Library tab, owned by the shell so it survives rebuilds
/// and tab switches: the source shown, the link field and its relay mode,
/// the selected Jellyfin card (details panel) and the last Jellyfin pick.
class MediaPickerController extends ChangeNotifier {
  MediaPickerController(
      {String mediaPath = '', String linkUrl = '', JellyfinMedia? jellyfin, MediaKind? source})
      : link = TextEditingController(text: linkUrl),
        file = TextEditingController(text: mediaPath),
        _jellyfin = jellyfin,
        _selected = jellyfin == null ? null : JellyfinSelection(jellyfin.serverId, jellyfin.itemId),
        _source = source ?? MediaKind.jellyfin {
    link.addListener(notifyListeners);
    file.addListener(notifyListeners);
  }

  final TextEditingController link;
  final TextEditingController file;
  MediaKind _source;
  // Through me unless picked otherwise (Library → Link).
  LinkRelay _linkRelay = LinkRelay.me;
  JellyfinMedia? _jellyfin;
  JellyfinSelection? _selected;

  LinkRelay get linkRelay => _linkRelay;
  set linkRelay(LinkRelay v) {
    if (v == _linkRelay) return;
    _linkRelay = v;
    notifyListeners();
  }

  /// The last Jellyfin item picked (restored from the last put-up).
  JellyfinMedia? get jellyfin => _jellyfin;

  /// Picks a Jellyfin item: selects its card and switches to Jellyfin.
  void pickJellyfin(JellyfinMedia? media) {
    _jellyfin = media;
    _selected = media == null ? null : JellyfinSelection(media.serverId, media.itemId);
    _source = MediaKind.jellyfin;
    notifyListeners();
  }

  /// The selected Jellyfin card (details panel open), or null.
  JellyfinSelection? get selected => _selected;
  void select(JellyfinSelection? s) {
    if (s == _selected && s?.item == _selected?.item) return;
    _selected = s;
    notifyListeners();
  }

  MediaKind get source => _source;
  set source(MediaKind v) {
    if (v == _source) return;
    _source = v;
    notifyListeners();
  }

  /// What the Link or File source holds; for Jellyfin the last pick.
  PickedMedia? get selection {
    switch (_source) {
      case MediaKind.link:
        final url = link.text.trim();
        return url.isEmpty ? null : LinkMedia(url, relay: _linkRelay);
      case MediaKind.file:
        final path = file.text.trim();
        return path.isEmpty ? null : FileMedia(path);
      case MediaKind.jellyfin:
        return _jellyfin;
    }
  }

  /// Drops pasted text where it belongs: http(s) into Link, else File.
  void pasteText(String text) {
    final parsed = parseMediaInput(text);
    if (parsed.linkUrl.isNotEmpty) {
      link.text = parsed.linkUrl;
      source = MediaKind.link;
    } else if (parsed.mediaPath.isNotEmpty) {
      file.text = parsed.mediaPath;
      source = MediaKind.file;
    }
  }

  @override
  void dispose() {
    link.dispose();
    file.dispose();
    super.dispose();
  }
}
