import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart';

import '../app/app_graph.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import '../widgets/text_focus.dart';
import 'avatar.dart';
import 'person_card.dart' show PersonHover, PersonRef;

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
    AppScope.of(context).coordinator.sendChat(widget.chat.text);
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
                    tooltip: 'Show joins, BRBs, seeks and other activity',
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
                final all = AppScope.of(context).coordinator.feedLog.value;
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
            for (final (label, action) in _messageActions(context, item.reason, link))
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
                // The sender's card on their picture and name.
                PersonHover(
                  person: PersonRef(id: item.actorId, name: item.actor),
                  child: StatusAvatar(
                      info: avatarForName(item.actor, AppScope.of(context).coordinator, item.actorId),
                      size: 34,
                      badges: false),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: PersonHover(
                              person: PersonRef(id: item.actorId, name: item.actor),
                              child: Text(item.actor,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
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
List<(String, VoidCallback)> _messageActions(BuildContext context, String text, String? link) => [
      (ReuseText.copyMessage, () => copyToClipboard(context, text, done: 'Message copied')),
      if (link != null) ...[
        (ReuseText.copyLink, () => copyToClipboard(context, link, done: 'Link copied')),
        (ReuseText.openInBrowser, () => openLink(context, link)),
      ],
    ];

/// Right-click beside a chat message: [_messageActions] in the app's menu.
Future<void> _messageMenu(BuildContext context, String text, String? link) async {
  final actions = _messageActions(context, text, link);
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
    case 'play':
      return (Icons.play_arrow, Colors.green, 'pressed play');
    case 'pause':
      return (Icons.pause, Colors.orange, 'paused');
    case 'brb':
      final who = f.target;
      return (Icons.coffee_rounded, Colors.amber, who == null || who.isEmpty ? 'is BRB' : 'waits for $who (BRB)');
    case 'back':
      return (Icons.waving_hand_rounded, Colors.green, "is back");
    case 'continue':
      final who = f.target;
      return (Icons.fast_forward_rounded, Colors.orange,
          who == null || who.isEmpty ? 'went on without the others' : "doesn't wait for $who");
    case 'seek':
      return (Icons.fast_forward, scheme.primary, 'seeked');
    case 'swap':
      return (Icons.swap_horiz, scheme.primary, f.reason == 'restore' ? 'put back what was playing' : 'changed the media');
    case 'gone':
      return (Icons.cloud_off, Colors.orange, 'lost signal');
    case 'return':
      return (Icons.cloud_done, Colors.green, 'is back');
    case 'afk':
      return (Icons.snooze_rounded, Colors.blueGrey, 'is AFK');
    case 'out':
      final who = f.target;
      final why = switch (f.reason) {
        'minimised' => ' · minimised',
        'closed' => ' · closed the player',
        'continue' => ' · the others went on',
        _ => '',
      };
      return (Icons.visibility_off_rounded, Colors.blueGrey, '${who == null || who.isEmpty ? 'is out' : 'set $who out'}$why');
    case 'in':
      return (Icons.login, Colors.green, 'joined');
    case 'queue-add':
      return (Icons.playlist_add_rounded, scheme.primary, 'added ${f.target ?? ''} to Up next');
    case 'queue-remove':
      return (Icons.playlist_remove_rounded, Colors.grey, 'removed ${f.target ?? ''} from Up next');
    case 'queue-skip':
      final why = f.reason.isEmpty ? '' : ' · ${f.reason}';
      return (Icons.redo_rounded, Colors.orange, 'skipped ${f.target ?? ''}$why');
    case 'advance-cancel':
      final what = f.target == null || f.target!.isEmpty ? '' : ' (${f.target} is off Up next)';
      return (Icons.cancel_outlined, Colors.grey, 'cancelled what plays next$what');
    case 'fetch-fail':
      return (Icons.cloud_off, Colors.red, "couldn't fetch ${f.target ?? 'the video'}");
    default:
      final target = f.target == null || f.target!.isEmpty ? '' : ' ${f.target}';
      return (Icons.info_outline, Colors.grey, '${f.action}$target');
  }
}

/// The server's own lines (waiting for a video and going on, the end, an
/// Up next item nobody here can put up).
(IconData, Color, String) serverFeedStyle(FeedMessage f) => switch (f.action) {
      'resume' => (Icons.play_arrow, Colors.green, 'Playback resumed'),
      'finished' => (Icons.stop_circle_outlined, Colors.grey, 'Finished'),
      'queue-skip' => (
          Icons.redo_rounded,
          Colors.orange,
          'Skipped ${f.target ?? ''}${f.reason.isEmpty ? '' : ' · ${f.reason}'}'
        ),
      _ => (Icons.pause, Colors.orange, 'Waiting for a video to load'),
    };

String _clock(DateTime at) {
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}
