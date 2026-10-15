import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart';

import '../state/session_state.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import '../widgets/text_focus.dart';
import 'avatar.dart';

/// Activity lines (joins, ready, seeks...) between the messages: off by
/// default, kept for the app's run.
final showActivity = ValueNotifier(false);

/// Side panel: chat with avatars, other activity as quiet lines (behind
/// the "Activity" toggle), and the message field. Width is fixed; the
/// shell slides it in and out. The field takes focus on open; Tab and Esc
/// in it close the panel.
class ChatPanel extends StatefulWidget {
  static const width = 340.0;
  final TextEditingController chat;
  final FocusNode chatFocus;
  final VoidCallback onClose;
  const ChatPanel({super.key, required this.chat, required this.chatFocus, required this.onClose});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  // Where focus was before the field took it; it goes back there on close
  // (else a field behind could take it, and Space with it).
  FocusNode? _before;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final before = FocusManager.instance.primaryFocus;
      if (before != widget.chatFocus) _before = before;
      widget.chatFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    final before = _before;
    if (before != null && before.context != null && before.canRequestFocus && !textInputFocused(before)) {
      before.requestFocus();
    } else if (textInputFocused()) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    super.dispose();
  }

  void _send() {
    SessionState.instance.coordinator.sendChat(widget.chat.text);
    widget.chat.clear();
    widget.chatFocus.requestFocus();
  }

  KeyEventResult _fieldKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.tab && e.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    widget.onClose();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('chat-panel'),
      width: ChatPanel.width,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                const Text('Chat', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                ValueListenableBuilder<bool>(
                  valueListenable: showActivity,
                  builder: (context, on, _) => FilterChip(
                    key: const ValueKey('chat-activity'),
                    label: const Text('Activity', style: TextStyle(fontSize: 12)),
                    tooltip: 'Show joins, ready, seeks and other activity',
                    selected: on,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (v) => showActivity.value = v,
                  ),
                ),
                IconButton(tooltip: 'Close (Tab)', onPressed: widget.onClose, icon: const Icon(Icons.close, size: 18)),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: showActivity,
              builder: (context, activity, _) => PartyWatch(builder: (context) {
                final all = SessionState.instance.coordinator.feedLog.value;
                final log = activity ? all : [for (final f in all) if (f.action == 'chat') f];
                if (log.isEmpty) {
                  return Center(
                    child: Text(activity ? 'Nothing yet' : 'No messages yet',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
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
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _fieldKey,
              child: TextField(
                key: const ValueKey('chat-field'),
                controller: widget.chat,
                focusNode: widget.chatFocus,
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
      final link = firstLinkIn(item.reason);
      // Right-click on the text: its selection menu plus the whole message
      // and its link; beside it, the same as the app's menu.
      final message = SelectableText(
        item.reason,
        contextMenuBuilder: (context, state) => AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: [
            ...state.contextMenuButtonItems,
            for (final (label, action) in _messageActions(item.reason, link))
              ContextMenuButtonItem(
                label: label,
                onPressed: () {
                  state.hideToolbar();
                  action();
                },
              ),
          ],
        ),
      );
      return Builder(
        builder: (context) => GestureDetector(
          onSecondaryTap: () => _messageMenu(context, item.reason, link),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusAvatar(info: avatarForName(item.actor, null, item.actorId), size: 34, badges: false),
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
                      message,
                    ],
                  ),
                ),
              ],
            ),
          ),
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

/// The first http(s) link in [text], if any.
String? firstLinkIn(String text) => RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(text)?.group(0);

/// What a chat message offers: Copy message, and its link's Copy link and
/// Open in browser.
List<(String, VoidCallback)> _messageActions(String text, String? link) => [
      (ReuseText.copyMessage, () => copyToClipboard(text, done: 'Message copied')),
      if (link != null) ...[
        (ReuseText.copyLink, () => copyToClipboard(link, done: 'Link copied')),
        (ReuseText.openInBrowser, () => openLink(link)),
      ],
    ];

/// Right-click beside a chat message: [_messageActions] in the app's menu.
Future<void> _messageMenu(BuildContext context, String text, String? link) async {
  final actions = _messageActions(text, link);
  final pick = await showAppMenu<int>(context, items: [
    for (final (i, (label, _)) in actions.indexed) AppMenuItem(value: i, label: label),
  ]);
  if (pick != null) actions[pick].$2();
}

/// Icon, colour and wording of a member's feed action.
(IconData, Color, String) feedStyle(FeedMessage f, ColorScheme scheme) {
  switch (f.action) {
    case 'join':
      return (Icons.login, Colors.green, 'joined');
    case 'leave':
      final reason = f.reason == 'grace' ? ' · lost signal too long' : '';
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
    case 'gone':
      return (Icons.cloud_off, Colors.orange, 'lost signal');
    case 'return':
      return (Icons.cloud_done, Colors.green, 'is back');
    case 'away':
      final who = f.target;
      final why = f.reason.isEmpty ? '' : ' · ${f.reason}';
      return (Icons.bedtime, Colors.blueGrey, '${who == null || who.isEmpty ? 'is sitting out' : 'sat $who out'}$why');
    case 'in':
      return (Icons.login, Colors.green, 'joined back');
    case 'queue-add':
      return (Icons.playlist_add_rounded, scheme.primary, 'added ${f.target ?? ''} to Up next');
    case 'queue-remove':
      return (Icons.playlist_remove_rounded, Colors.grey, 'removed ${f.target ?? ''} from Up next');
    case 'queue-skip':
      final why = f.reason.isEmpty ? '' : ' · ${f.reason}';
      return (Icons.redo_rounded, Colors.orange, 'skipped ${f.target ?? ''}$why');
    case 'fetch-fail':
      return (Icons.cloud_off, Colors.red, "couldn't fetch ${f.target ?? 'the video'}");
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
