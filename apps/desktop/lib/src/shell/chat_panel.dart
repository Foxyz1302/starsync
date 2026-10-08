import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../state/session_state.dart';
import 'avatar.dart';

/// Side panel: chat with avatars, other activity as quiet lines, and the
/// message field. Width is fixed; the shell slides it in and out.
class ChatPanel extends StatelessWidget {
  static const width = 340.0;
  final TextEditingController chat;
  final FocusNode chatFocus;
  final VoidCallback onClose;
  const ChatPanel({super.key, required this.chat, required this.chatFocus, required this.onClose});

  void _send() {
    SessionState.instance.coordinator.sendChat(chat.text);
    chat.clear();
    chatFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('chat-panel'),
      width: width,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                const Text('Chat & activity', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(tooltip: 'Close (Tab)', onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
              ],
            ),
          ),
          Expanded(
            child: PartyWatch(builder: (context) {
              final log = SessionState.instance.coordinator.feedLog.value;
              if (log.isEmpty) {
                return Center(
                  child: Text('Nothing yet', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                );
              }
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: log.length,
                itemBuilder: (context, i) => ActivityRow(item: log[log.length - 1 - i]),
              );
            }),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const ValueKey('chat-field'),
              controller: chat,
              focusNode: chatFocus,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Message (Enter)',
                isDense: true,
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                suffixIcon: IconButton(tooltip: 'Send', onPressed: _send, icon: const Icon(Icons.send, size: 18)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One feed line: a chat message with the sender's avatar, anything else
/// as an icon and "who did what".
class ActivityRow extends StatelessWidget {
  final FeedMessage item;
  const ActivityRow({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = _clock(item.at);
    if (item.action == 'chat') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusAvatar(info: avatarForName(item.actor), size: 34, badges: false),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(item.actor,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 6),
                      Text(time, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
                    ],
                  ),
                  SelectableText(item.reason),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final (icon, color, text) = item.actor == 'server' ? serverFeedStyle(item) : feedStyle(item, scheme);
    final line = item.actor == 'server' ? text : '${item.actor} $text';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(line, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
          Text(time, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Icon, colour and wording of a member's feed action.
(IconData, Color, String) feedStyle(FeedMessage f, ColorScheme scheme) {
  switch (f.action) {
    case 'join':
      return (Icons.login, Colors.green, 'joined');
    case 'leave':
      final reason = f.reason == 'silent too long' ? ' · timed out' : (f.reason.isEmpty ? '' : ' · ${f.reason}');
      return (Icons.logout, Colors.grey, 'left$reason');
    case 'ready':
      return (Icons.check_circle, Colors.green, 'is ready');
    case 'unready':
      return (Icons.radio_button_unchecked, Colors.grey, "isn't ready");
    case 'force-ready':
      return (Icons.how_to_reg, Colors.orange, 'marked ${f.target ?? ''} ready');
    case 'force-unready':
      return (Icons.how_to_reg, Colors.orange, 'marked ${f.target ?? ''} not ready');
    case 'force-play':
      return (Icons.play_arrow, Colors.green, 'started playback for everyone');
    case 'force-hold':
      return (Icons.pause, Colors.orange, 'held playback for everyone');
    case 'seek':
      return (Icons.fast_forward, scheme.primary, 'seeked');
    case 'swap':
      return (Icons.swap_horiz, scheme.primary, 'changed the media');
    case 'stale':
      return (Icons.cloud_off, Colors.orange, 'lost signal');
    case 'kick':
      final reason = f.reason.isEmpty ? '' : ' · ${f.reason}';
      return (Icons.gavel, Colors.red, 'kicked ${f.target ?? ''}$reason');
    default:
      final target = f.target == null || f.target!.isEmpty ? '' : ' ${f.target}';
      return (Icons.info_outline, Colors.grey, '${f.action}$target');
  }
}

/// The server's own lines (pause / resume).
(IconData, Color, String) serverFeedStyle(FeedMessage f) => switch (f.action) {
      'resume' => (Icons.play_arrow, Colors.green, 'Playback resumed'),
      _ => (Icons.pause, Colors.orange, 'Playback paused · waiting for readiness'),
    };

String _clock(DateTime at) {
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}
