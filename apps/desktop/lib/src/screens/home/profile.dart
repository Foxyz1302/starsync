import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/session_state.dart';
import '../../widgets/avatar_pipeline.dart';
import 'ui.dart';

/// Display name + avatar, shared by the Home profile row and Settings.
/// Backed by [SessionState.lastForm]; every change is persisted. The
/// avatar goes through [encodeAvatar] (the same shrink the server gets)
/// before its path is stored, and the encoded bytes are the preview.
class Profile {
  static final Profile instance = Profile._();
  Profile._();

  final name = signal('');
  final preview = signal<Uint8List?>(null);
  final error = signal<String?>(null);
  final picking = signal(false);
  bool _loaded = false;

  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final f = SessionState.instance.lastForm;
    name.value = f.name;
    _refreshPreview(f.avatarPath);
  }

  Future<void> _refreshPreview(String path) async {
    try {
      final b64 = await encodeAvatar(path);
      preview.value = b64.isEmpty ? null : base64Decode(b64);
    } catch (_) {
      preview.value = null;
    }
  }

  void setName(String value) {
    name.value = value.trim();
    SessionState.instance.lastForm.name = value.trim();
    _save();
  }

  Future<void> pickAvatar() async {
    if (picking.peek()) return;
    picking.value = true;
    error.value = null;
    try {
      final List<PlatformFile> files;
      try {
        files = await FilePicker.pickFiles(
          dialogTitle: 'Pick avatar image',
          type: FileType.custom,
          allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        );
      } catch (_) {
        error.value = 'file dialog unavailable — try again';
        return;
      }
      final path = files.isEmpty ? null : files.first.path;
      if (path == null) return;
      final String b64;
      try {
        b64 = await encodeAvatar(path);
      } on FormatException catch (e) {
        error.value = e.message;
        return;
      } catch (_) {
        error.value = 'could not read that image — pick a PNG, JPG or WebP photo';
        return;
      }
      SessionState.instance.lastForm.avatarPath = path;
      preview.value = b64.isEmpty ? null : base64Decode(b64);
      await _save();
    } finally {
      picking.value = false;
    }
  }

  Future<void> clearAvatar() async {
    SessionState.instance.lastForm.avatarPath = '';
    preview.value = null;
    error.value = null;
    await _save();
  }

  Future<void> _save() async {
    try {
      await SessionState.instance.saveForm();
    } catch (_) {
      error.value = 'could not save profile — try again';
    }
  }
}

/// Avatar circle with the initial as fallback.
class ProfileAvatar extends StatelessWidget {
  final double radius;
  const ProfileAvatar({super.key, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final p = Profile.instance;
    return SignalBuilder(builder: (context) {
      final img = p.preview.value;
      final n = p.name.value;
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        backgroundImage: img != null ? MemoryImage(img) : null,
        child: img != null
            ? null
            : p.picking.value
                ? SizedBox(
                    width: radius * 0.8,
                    height: radius * 0.8,
                    child: const CircularProgressIndicator(strokeWidth: 2))
                : Text(n.isEmpty ? '?' : n[0].toUpperCase(),
                    style: TextStyle(fontSize: radius * 0.8)),
      );
    });
  }
}

/// Avatar (tap to change) + name field. Used inline in Settings and in
/// the Home profile dialog.
class ProfileEditor extends StatefulWidget {
  final bool autofocus;
  final VoidCallback? onSubmitted;
  const ProfileEditor({super.key, this.autofocus = false, this.onSubmitted});

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final _name = TextEditingController(text: Profile.instance.name.peek());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Profile.instance;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Change avatar',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: p.pickAvatar,
            child: const ProfileAvatar(radius: 36),
          ),
        ),
        const SizedBox(width: kGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.autofocus,
                decoration: fieldDecoration('Display name'),
                onChanged: p.setName,
                onSubmitted: (_) => widget.onSubmitted?.call(),
              ),
              const SizedBox(height: 4),
              SignalBuilder(builder: (context) {
                final err = p.error.value;
                return Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                        onPressed: p.pickAvatar,
                        child: const Text('Change avatar')),
                    if (p.preview.value != null)
                      TextButton(
                          onPressed: p.clearAvatar,
                          child: const Text('Remove avatar')),
                    if (err != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(err,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.error)),
                      ),
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> showProfileDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      title: const Text('Profile'),
      content: SizedBox(
        width: 380,
        child: ProfileEditor(
          autofocus: true,
          onSubmitted: () => Navigator.pop(context),
        ),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    ),
  );
}

/// Home's top-left: avatar + name, click to edit.
class ProfileChip extends StatelessWidget {
  const ProfileChip({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Profile.instance;
    return Tooltip(
      message: 'Edit profile',
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius),
        onTap: () => showProfileDialog(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ProfileAvatar(radius: 20),
              const SizedBox(width: 12),
              SignalBuilder(builder: (context) {
                final n = p.name.value;
                final t = Theme.of(context).textTheme;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(n.isEmpty ? 'Set your name' : n,
                        style: t.titleMedium?.copyWith(
                            color: n.isEmpty ? Colors.grey : null)),
                    Text('Edit profile',
                        style: t.bodySmall?.copyWith(color: Colors.grey)),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
