import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/media_input.dart';
import 'ui.dart';

const videoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts'];

enum MediaKind { jellyfin, link, file }

/// What to play: at most one of the two is non-empty; both empty = none.
typedef MediaSelection = ({String mediaPath, String linkUrl});

/// State of a [MediaPicker], owned by whoever hosts it (Home's Host tab,
/// later the session's swap panel) so it survives rebuilds.
class MediaPickerController extends ChangeNotifier {
  MediaPickerController({String mediaPath = '', String linkUrl = '', MediaKind? source})
      : link = TextEditingController(text: linkUrl),
        file = TextEditingController(text: mediaPath),
        _source = source ?? (linkUrl.isNotEmpty ? MediaKind.link : MediaKind.file) {
    link.addListener(notifyListeners);
    file.addListener(notifyListeners);
  }

  final TextEditingController link;
  final TextEditingController file;
  MediaKind _source;
  String? _notice;

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

  MediaSelection get selection => switch (_source) {
        MediaKind.link => (mediaPath: '', linkUrl: link.text.trim()),
        MediaKind.file => (mediaPath: file.text.trim(), linkUrl: ''),
        MediaKind.jellyfin => (mediaPath: '', linkUrl: ''),
      };

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
  final ValueChanged<MediaSelection>? onChanged;
  /// Enter in a field.
  final VoidCallback? onSubmit;
  final VoidCallback? onOpenIntegrations;
  final bool enabled;
  final bool autofocus;
  const MediaPicker({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmit,
    this.onOpenIntegrations,
    this.enabled = true,
    this.autofocus = false,
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
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: AbsorbPointer(
        absorbing: !widget.enabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<MediaKind>(
                key: const ValueKey('media-source'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: MediaKind.jellyfin,
                      icon: Icon(Icons.video_library_outlined),
                      label: Text('Jellyfin')),
                  ButtonSegment(
                      value: MediaKind.link, icon: Icon(Icons.link), label: Text('Link')),
                  ButtonSegment(
                      value: MediaKind.file,
                      icon: Icon(Icons.insert_drive_file_outlined),
                      label: Text('File')),
                ],
                selected: {source},
                onSelectionChanged: (s) => _c.source = s.first,
              ),
            ),
            const SizedBox(height: kGap),
            switch (source) {
              MediaKind.jellyfin =>
                _JellyfinPlaceholder(onOpenIntegrations: widget.onOpenIntegrations),
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
            },
          ],
        ),
      ),
    );
  }
}

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

/// Where the Jellyfin library grid will go: ghost posters that fill the
/// width, dimmed, with the "coming soon" note on top.
class _JellyfinPlaceholder extends StatelessWidget {
  final VoidCallback? onOpenIntegrations;
  const _JellyfinPlaceholder({this.onOpenIntegrations});

  static const _posterWidth = 140.0;
  static const _rows = 2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(builder: (context, box) {
      final cols = ((box.maxWidth + 12) / (_posterWidth + 12)).floor().clamp(1, 40);
      return Stack(
        key: const ValueKey('media-jellyfin'),
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0.35,
            child: Column(
              spacing: 12,
              children: [
                for (var r = 0; r < _rows; r++)
                  Row(
                    spacing: 12,
                    children: [
                      for (var c = 0; c < cols; c++)
                        Expanded(
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          Panel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.video_library_outlined, size: 32, color: scheme.primary),
                const SizedBox(height: 8),
                Text('Link your Jellyfin in Integrations — coming soon',
                    textAlign: TextAlign.center, style: t.titleSmall),
                if (onOpenIntegrations != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                      onPressed: onOpenIntegrations, child: const Text('Open Integrations')),
                ],
              ],
            ),
          ),
        ],
      );
    });
  }
}
