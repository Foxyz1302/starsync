import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../jellyfin/accounts.dart';
import '../../jellyfin/picker_source.dart';
import '../../widgets/media_input.dart';
import 'picked_media.dart';
import 'ui.dart';

export 'picked_media.dart';

const videoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts'];

enum MediaKind { jellyfin, link, file }

/// State of a [MediaPicker], owned by whoever hosts it (Home's Host tab,
/// later the session's swap panel) so it survives rebuilds.
class MediaPickerController extends ChangeNotifier {
  MediaPickerController(
      {String mediaPath = '', String linkUrl = '', JellyfinMedia? jellyfin, MediaKind? source})
      : link = TextEditingController(text: linkUrl),
        file = TextEditingController(text: mediaPath),
        _jellyfin = jellyfin,
        _source = source ??
            (linkUrl.isNotEmpty
                ? MediaKind.link
                : mediaPath.isEmpty && jellyfin != null
                    ? MediaKind.jellyfin
                    : MediaKind.file) {
    link.addListener(notifyListeners);
    file.addListener(notifyListeners);
  }

  final TextEditingController link;
  final TextEditingController file;
  MediaKind _source;
  String? _notice;
  JellyfinMedia? _jellyfin;

  /// The Jellyfin item picked in the browser (kept while another source
  /// is shown).
  JellyfinMedia? get jellyfin => _jellyfin;

  /// Picks a Jellyfin item and switches to the Jellyfin source.
  void pickJellyfin(JellyfinMedia? media) {
    _jellyfin = media;
    _source = MediaKind.jellyfin;
    _notice = null;
    notifyListeners();
  }

  MediaKind get source => _source;
  set source(MediaKind v) {
    if (v == _source) return;
    _source = v;
    _notice = null;
    notifyListeners();
  }

  /// One-line hint under the fields (e.g. the file dialog failed).
  String? get notice => _notice;
  set notice(String? v) {
    _notice = v;
    notifyListeners();
  }

  /// What the visible source has selected; null = nothing.
  PickedMedia? get selection {
    switch (_source) {
      case MediaKind.link:
        final url = link.text.trim();
        return url.isEmpty ? null : LinkMedia(url);
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

/// Source segments (Jellyfin / Link / File) and the matching input.
/// Ctrl+V anywhere in the picker outside a text field pastes a link or path.
class MediaPicker extends StatefulWidget {
  final MediaPickerController controller;
  final ValueChanged<PickedMedia?>? onChanged;
  /// Enter in a field.
  final VoidCallback? onSubmit;
  final VoidCallback? onOpenIntegrations;
  final bool enabled;
  final bool autofocus;
  /// Defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  /// Jellyfin source only: the browser's "bigger" toggle.
  final VoidCallback? onToggleExpanded;
  final bool expanded;
  const MediaPicker({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmit,
    this.onOpenIntegrations,
    this.enabled = true,
    this.autofocus = false,
    this.jellyfin,
    this.onToggleExpanded,
    this.expanded = false,
  });

  @override
  State<MediaPicker> createState() => _MediaPickerState();
}

class _MediaPickerState extends State<MediaPicker> {
  MediaPickerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(MediaPicker old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    widget.onChanged?.call(_c.selection);
    if (mounted) setState(() {});
  }

  Future<String?> _clipboard() async {
    try {
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> _pasteAnywhere() async {
    final text = await _clipboard();
    if (text != null && text.isNotEmpty) _c.pasteText(text);
  }

  Future<void> _pasteLink() async {
    final text = await _clipboard();
    if (text != null && text.isNotEmpty) _c.link.text = text;
  }

  Future<void> _browse() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Pick media file',
        type: FileType.custom,
        allowedExtensions: videoExtensions,
      );
      final path = files.isEmpty ? null : files.first.path;
      if (path != null) {
        _c.file.text = path;
        _c.notice = null;
      }
    } catch (e) {
      _c.notice = 'File dialog unavailable (${e.runtimeType}) — paste the path instead';
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!widget.enabled || e is! KeyDownEvent || !ctrl || e.logicalKey != LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    // A focused text field handles its own paste.
    final inField = FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    if (inField) return KeyEventResult.ignored;
    _pasteAnywhere();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final source = _c.source;
    final Widget content = switch (source) {
      MediaKind.jellyfin => JellyfinPickerSource(
          accounts: widget.jellyfin ?? JellyfinAccounts.instance,
          selected: _c.jellyfin,
          onPick: _c.pickJellyfin,
          onOpenIntegrations: widget.onOpenIntegrations,
          onToggleExpanded: widget.onToggleExpanded,
          expanded: widget.expanded,
        ),
      MediaKind.link => _FieldRow(
          key: const ValueKey('media-link'),
          field: TextField(
            controller: _c.link,
            autofocus: widget.autofocus,
            decoration: fieldDecoration('Video link', hint: 'https://…/movie.mkv'),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => widget.onSubmit?.call(),
          ),
          button: OutlinedButton.icon(
            onPressed: _pasteLink,
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('Paste'),
          ),
          help: 'A direct http(s) link to a video file; everyone streams it from there.',
          notice: _c.notice,
        ),
      MediaKind.file => _FieldRow(
          key: const ValueKey('media-file'),
          field: TextField(
            controller: _c.file,
            decoration: fieldDecoration('Video file', hint: 'Path to a video on this computer'),
            onSubmitted: (_) => widget.onSubmit?.call(),
          ),
          button: OutlinedButton.icon(
            onPressed: _browse,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Browse'),
          ),
          help: 'Friends stream it from you while you watch. Optional — you can host without media.',
          notice: _c.notice,
        ),
    };
    final segments = Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<MediaKind>(
        key: const ValueKey('media-source'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
              value: MediaKind.jellyfin,
              icon: Icon(Icons.video_library_outlined),
              label: Text('Jellyfin')),
          ButtonSegment(value: MediaKind.link, icon: Icon(Icons.link), label: Text('Link')),
          ButtonSegment(
              value: MediaKind.file,
              icon: Icon(Icons.insert_drive_file_outlined),
              label: Text('File')),
        ],
        selected: {source},
        onSelectionChanged: (s) => _c.source = s.first,
      ),
    );
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: AbsorbPointer(
        absorbing: !widget.enabled,
        // The browser fills the height it is given; in an unbounded
        // (scrolling) parent it gets a fixed one.
        child: LayoutBuilder(builder: (context, box) {
          final fill = source == MediaKind.jellyfin;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: fill && box.hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
            children: [
              segments,
              const SizedBox(height: kGap),
              if (!fill)
                content
              else if (box.hasBoundedHeight)
                Expanded(child: content)
              else
                SizedBox(height: jellyfinPickerHeight, child: content),
            ],
          );
        }),
      ),
    );
  }
}

/// Height of the Jellyfin browser when the picker sits in a scroll view.
const jellyfinPickerHeight = 640.0;

class _FieldRow extends StatelessWidget {
  final Widget field;
  final Widget button;
  final String help;
  final String? notice;
  const _FieldRow(
      {super.key, required this.field, required this.button, required this.help, this.notice});

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kFieldMaxWidth + 140),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 12),
                button,
              ],
            ),
            const SizedBox(height: 8),
            Text(notice ?? help, style: small),
          ],
        ),
      ),
    );
  }
}
