import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/session_state.dart';
import 'avatar_pipeline.dart';

/// Profile card for the connect screen.
///
/// Lives in a fixed corner card outside the scrolling form, so Host/Join
/// field changes below never move it. Name edits write back to
/// [SessionState.lastForm] on every change (persisted on submit); avatar
/// changes by tapping the circle, validated through [encodeAvatar] before
/// the path is stored, with the encoded bytes shown as the preview.
class ConnectProfileCard extends StatefulWidget {
  final TextEditingController name;
  const ConnectProfileCard({super.key, required this.name});

  @override
  State<ConnectProfileCard> createState() => _ConnectProfileCardState();
}

class _ConnectProfileCardState extends State<ConnectProfileCard> {
  late String _avatarPath;
  Uint8List? _preview;
  String? _error;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _avatarPath = SessionState.instance.lastForm.avatarPath;
    _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    String b64;
    try {
      b64 = await encodeAvatar(_avatarPath);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _preview = b64.isEmpty ? null : base64Decode(b64));
  }

  Future<void> _persistProfile() async {
    try {
      await SessionState.instance.saveForm();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'could not save profile — try again');
    }
  }

  Future<void> _pickAvatar() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final List<PlatformFile> files;
      try {
        files = await FilePicker.pickFiles(
          dialogTitle: 'Pick avatar image',
          type: FileType.custom,
          allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        );
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = 'file dialog unavailable — try again');
        return;
      }
      if (files.isEmpty) return;
      final path = files.first.path;
      if (path == null || !mounted) return;
      late final String b64;
      try {
        b64 = await encodeAvatar(path);
      } on FormatException catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() => _error =
            'could not read that image — pick a PNG, JPG or WebP photo');
        return;
      }
      _avatarPath = path;
      SessionState.instance.lastForm.avatarPath = path;
      await _persistProfile();
      if (!mounted) return;
      setState(() => _preview = b64.isEmpty ? null : base64Decode(b64));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _pickAvatar,
          child: Tooltip(
            message: 'Change avatar',
            child: CircleAvatar(
              radius: 22,
              backgroundColor: Colors.grey.shade800,
              backgroundImage: _preview != null ? MemoryImage(_preview!) : null,
              child: _preview != null
                  ? null
                  : _picking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : ListenableBuilder(
                          listenable: widget.name,
                          builder: (context, _) {
                            final t = widget.name.text.trim();
                            return Text(t.isEmpty ? '?' : t[0].toUpperCase());
                          },
                        ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 180,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: widget.name,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  isDense: true,
                ),
                onChanged: (_) {
                  SessionState.instance.lastForm.name = widget.name.text.trim();
                },
                onSubmitted: (_) => _persistProfile(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
