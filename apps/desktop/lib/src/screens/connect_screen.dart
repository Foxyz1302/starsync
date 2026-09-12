import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../session/session_coordinator.dart';
import '../state/session_state.dart';
import '../widgets/avatar_pipeline.dart';
import '../widgets/media_input.dart';
import '../widgets/user_section.dart';
import '../widgets/window_buttons.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _secret;
  late final TextEditingController _name;
  late final TextEditingController _media;
  late final void Function() _stopKickWatch;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _dialogOpen = false;
  int _attempt = 0;
  String? _lastKickShown;

  @override
  void initState() {
    super.initState();
    final f = SessionState.instance.lastForm;
    _host = TextEditingController(text: f.host);
    _port = TextEditingController(text: f.port);
    _secret = TextEditingController(text: f.secret);
    _name = TextEditingController(text: f.name);
    _media = TextEditingController(text: f.linkUrl.isNotEmpty ? f.linkUrl : f.mediaPath);
    _stopKickWatch = effect(() {
      final kick = SessionState.instance.coordinator.kickReason.value;
      if (kick == null || kick.isEmpty) {
        _lastKickShown = null;
        return;
      }
      if (kick == _lastKickShown) return;
      _lastKickShown = kick;
      final reason = kick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showKickedDialog(reason);
      });
    });
  }

  @override
  void dispose() {
    _stopKickWatch();
    _host.dispose();
    _port.dispose();
    _secret.dispose();
    _name.dispose();
    _media.dispose();
    super.dispose();
  }

  String _actionable(Object e) {
    if (e is FormatException) return e.message;
    return 'check the form and try again';
  }

  Future<ConnectParams> _buildParams(ConnectMode mode) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    if (_secret.text.isEmpty) {
      throw const FormatException('room password required');
    }
    if (_name.text.trim().isEmpty) {
      throw const FormatException('display name required');
    }
    String avatar = '';
    try {
      avatar = await encodeAvatar(SessionState.instance.lastForm.avatarPath);
    } on FormatException catch (e) {
      throw FormatException(e.message);
    } catch (_) {
      throw const FormatException('could not process that avatar — pick a PNG, JPG or WebP photo');
    }
    final parsed = parseMediaInput(_media.text);
    if (mode == ConnectMode.host && parsed.mediaPath.isNotEmpty && !await File(parsed.mediaPath).exists()) {
      throw const FormatException('media file not found — check the path or pick again with Browse');
    }
    return ConnectParams(
      host: _host.text.trim().isEmpty ? '127.0.0.1' : _host.text.trim(),
      port: port,
      secret: _secret.text,
      name: _name.text.trim(),
      avatar: avatar,
      mediaPath: mode == ConnectMode.host ? parsed.mediaPath : '',
      linkUrl: mode == ConnectMode.host ? parsed.linkUrl : '',
    );
  }

  Future<void> _submit(ConnectMode mode) async {
    final myAttempt = ++_attempt;
    final session = SessionState.instance;
    setState(() {
      _error = null;
      _notice = null;
      _busy = true;
    });
    late final ConnectParams params;
    try {
      params = await _buildParams(mode);
    } catch (e) {
      if (!mounted || myAttempt != _attempt) return;
      setState(() {
        _error = _actionable(e);
        _busy = false;
      });
      return;
    }
    final parsed = parseMediaInput(_media.text);
    final form = SessionState.instance.lastForm
      ..host = _host.text.trim()
      ..port = _port.text.trim()
      ..secret = _secret.text
      ..name = _name.text.trim()
      ..mediaPath = parsed.mediaPath
      ..linkUrl = parsed.linkUrl;
    try {
      if (mode == ConnectMode.host) {
        await session.host(params, form);
      } else {
        await session.join(params, form);
      }
    } catch (e) {
      if (!mounted || myAttempt != _attempt) return;
      final kick = session.coordinator.kickReason.peek();
      setState(() => _busy = false);
      if (kick != null && kick.isNotEmpty) {
        await _showKickedDialog(kick);
      } else {
        await _showConnectionDialog('$e');
      }
      return;
    }
    if (myAttempt != _attempt) {
      try {
        await session.leave();
        await session.stopServer();
      } catch (_) {}
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancel() async {
    _attempt++;
    try {
      await SessionState.instance.coordinator.cancelConnect();
      await SessionState.instance.stopServer();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = 'connection cancelled';
    });
  }

  Future<void> _showKickedDialog(String reason) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('You were removed'),
          content: Text(reason.isEmpty ? 'The host removed you from the room.' : reason),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _showConnectionDialog(String message) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not connect'),
          content: Text(message),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _browse(TextEditingController target, {required String dialogTitle, List<String>? allowedExtensions}) async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: allowedExtensions == null ? FileType.any : FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (files.isEmpty) return;
      final path = files.first.path;
      if (path != null && mounted) setState(() => target.text = path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = 'file dialog unavailable (${e.runtimeType}) — paste the path manually');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: DragToMoveArea(
          child: AppBar(
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => session.route.value = AppRoute.welcome),
            title: SignalBuilder(builder: (context) => Text(session.connectMode.value == ConnectMode.host ? 'Host room' : 'Join room')),
            actions: const [WindowButtons()],
          ),
        ),
      ),
      body: Stack(
        alignment: AlignmentGeometry.center,
        children: [
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ConnectProfileCard(name: _name),
                ),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                if (_error != null)
                  Card(
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                  ),
                if (_notice != null) Text(_notice!),
                SignalBuilder(
                  builder: (context) {
                    final mode = session.connectMode.value;
                    return SegmentedButton<ConnectMode>(
                      segments: const [
                        ButtonSegment(value: ConnectMode.host, label: Text('Host')),
                        ButtonSegment(value: ConnectMode.join, label: Text('Join')),
                      ],
                      selected: {mode},
                      onSelectionChanged: (s) => session.connectMode.value = s.first,
                    );
                  },
                ),
                const SizedBox(height: 16),
                SignalBuilder(
                  builder: (context) {
                    if (session.connectMode.value == ConnectMode.host) {
                      return const SizedBox.shrink();
                    }
                    return TextField(
                      controller: _host,
                      decoration: const InputDecoration(labelText: 'Host address'),
                    );
                  },
                ),
                TextField(
                  controller: _port,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: _secret,
                  decoration: const InputDecoration(labelText: 'Room password'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                SignalBuilder(
                  builder: (context) {
                    if (session.connectMode.value == ConnectMode.host) {
                      return Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _media,
                              decoration: const InputDecoration(labelText: 'Media (file path or http(s) URL)'),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _browse(
                              _media,
                              dialogTitle: 'Pick media file',
                              allowedExtensions: const ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts'],
                            ),
                            child: const Text('Browse'),
                          ),
                        ],
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const SizedBox(height: 16),
                SignalBuilder(
                  builder: (context) {
                    final mode = session.connectMode.value;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ElevatedButton(
                          onPressed: _busy ? null : () => _submit(mode),
                          child: Text(
                            _busy
                                ? 'Connecting…'
                                : mode == ConnectMode.host
                                ? 'Start hosting'
                                : 'Join',
                          ),
                        ),
                        if (_busy) TextButton(onPressed: _cancel, child: const Text('Cancel')),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                const Text('Host opens ports and serves. Clients open nothing.', textAlign: TextAlign.center),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
