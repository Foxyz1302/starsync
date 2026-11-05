import 'dart:typed_data';

import 'package:sync_relay_core/core.dart' show FeedMessage;

// Everything that may become a toast, a sound, an attention request or an
// activity-log line, as one sealed type. Code that has news emits an
// event ([Notifier.notify]); only the notifier decides what the user sees
// and hears. Pure Dart (no Flutter): it can move to core with the policy.

sealed class AppEvent {
  const AppEvent();
}

// ---------------------------------------------------------------- feed

/// A server `feed` line (see PROTOCOL.md, `feed.action`); every one lands
/// in the activity log.
sealed class FeedEvent extends AppEvent {
  final FeedMessage feed;
  /// This member is the actor (its own chat, BRB, queue add...).
  final bool own;
  const FeedEvent(this.feed, {this.own = false});

  String get actor => feed.actor;

  /// [feed] as its typed event. [selfId]: this member's id (people are
  /// matched by `actorId` / `targetId`, never by name); [queueThumb]: the
  /// picture hash of the Up next item a `queue-add` added (from the state
  /// that came with it), '' when none.
  factory FeedEvent.of(FeedMessage f, {String selfId = '', String queueThumb = ''}) {
    bool isSelf(String id) => selfId.isNotEmpty && id == selfId;
    final own = isSelf(f.actorId);
    return switch (f.action) {
      'join' => MemberJoined(f, own: own),
      'leave' => MemberLeft(f, own: own),
      'gone' => MemberGone(f, own: own),
      'return' => MemberReturned(f, own: own),
      'brb' => MemberBrb(f, own: own, atYou: isSelf(f.targetId) && !isSelf(f.actorId)),
      'back' => MemberBackFromBrb(f, own: own),
      'afk' || 'out' => MemberOut(f,
          own: own,
          afk: f.action == 'afk',
          atYou: isSelf(f.targetId) && !isSelf(f.actorId),
          autoSelf: isSelf(f.actorId) && f.targetId.isEmpty && (f.action == 'afk' || f.reason == 'minimised')),
      'in' => MemberIn(f, own: own),
      'continue' => ContinuedWithout(f, own: own, atYou: isSelf(f.targetId) && !isSelf(f.actorId)),
      'play' => Played(f, own: own),
      'swap' => MediaSwapped(f, own: own),
      'seek' => Seeked(f, own: own),
      'pause' => Paused(f, own: own),
      'resume' => Resumed(f, own: own),
      'finished' => Finished(f, own: own),
      'chat' => ChatPosted(f, own: own),
      'rename' => MemberRenamed(f, own: own),
      'avatar' => AvatarChanged(f, own: own),
      'queue-add' => QueueAdded(f, own: own, thumb: queueThumb),
      'queue-remove' => QueueRemoved(f, own: own),
      'queue-skip' => QueueSkipped(f, own: own),
      'fetch-fail' => FetchFailed(f, own: own),
      _ => OtherFeed(f, own: own),
    };
  }
}

class MemberJoined extends FeedEvent {
  const MemberJoined(super.feed, {super.own});
}

/// Left for good (`reason` `bye`: the app closed or Leave; `grace`: gone
/// too long).
class MemberLeft extends FeedEvent {
  const MemberLeft(super.feed, {super.own});
}

/// Lost signal: gone for a while, kept in its grace period.
class MemberGone extends FeedEvent {
  const MemberGone(super.feed, {super.own});
}

/// Back within its grace after a [MemberGone].
class MemberReturned extends FeedEvent {
  const MemberReturned(super.feed, {super.own});
}

/// Someone is BRB (`brb`: the actor itself, or `target` set BRB by the
/// actor, "Wait for Bob"); [atYou]: someone else set this member BRB.
class MemberBrb extends FeedEvent {
  final bool atYou;
  const MemberBrb(super.feed, {super.own, this.atYou = false});
}

/// Back from BRB (`back`).
class MemberBackFromBrb extends FeedEvent {
  const MemberBackFromBrb(super.feed, {super.own});
}

/// Someone is out (`out`: the actor itself, or `target` set out by the
/// actor; `reason` `minimised` / `closed` / `continue`) or AFK (`afk`,
/// [afk]); [atYou]: someone else set this member out; [autoSelf]: this
/// app set it by itself (AFK, minimised).
class MemberOut extends FeedEvent {
  final bool afk;
  final bool atYou;
  final bool autoSelf;
  const MemberOut(super.feed, {super.own, this.afk = false, this.atYou = false, this.autoSelf = false});
}

/// Back from AFK or out (`in`): joined at the current moment.
class MemberIn extends FeedEvent {
  const MemberIn(super.feed, {super.own});
}

/// Someone continued without the ones the group waited for (`continue`;
/// `target` one member); [atYou]: without this member.
class ContinuedWithout extends FeedEvent {
  final bool atYou;
  const ContinuedWithout(super.feed, {super.own, this.atYou = false});
}

/// Someone pressed play (`play`).
class Played extends FeedEvent {
  const Played(super.feed, {super.own});
}

class MediaSwapped extends FeedEvent {
  const MediaSwapped(super.feed, {super.own});
}

class Seeked extends FeedEvent {
  const Seeked(super.feed, {super.own});
}

class Paused extends FeedEvent {
  const Paused(super.feed, {super.own});
}

class Resumed extends FeedEvent {
  const Resumed(super.feed, {super.own});
}

class Finished extends FeedEvent {
  const Finished(super.feed, {super.own});
}

/// A chat message (`reason` carries the text); [own]: this member sent it.
class ChatPosted extends FeedEvent {
  const ChatPosted(super.feed, {super.own});
}

class MemberRenamed extends FeedEvent {
  const MemberRenamed(super.feed, {super.own});
}

class AvatarChanged extends FeedEvent {
  const AvatarChanged(super.feed, {super.own});
}

/// Someone added an item to Up next (`target` its title); [thumb]: the
/// item's picture hash ('' when none).
class QueueAdded extends FeedEvent {
  final String thumb;
  const QueueAdded(super.feed, {super.own, this.thumb = ''});
}

class QueueRemoved extends FeedEvent {
  const QueueRemoved(super.feed, {super.own});
}

/// Up next skipped an item (`target` its title, `reason` why).
class QueueSkipped extends FeedEvent {
  const QueueSkipped(super.feed, {super.own});
}

/// The server could not fetch the current media.
class FetchFailed extends FeedEvent {
  const FetchFailed(super.feed, {super.own});
}

/// An action this app does not know (a newer server).
class OtherFeed extends FeedEvent {
  const OtherFeed(super.feed, {super.own});
}

// -------------------------------------------------------------- session

/// Someone poked this member.
class Nudged extends AppEvent {
  /// Their name; '' when unknown.
  final String name;
  const Nudged(this.name);
}

/// Another member's player cannot open the current media.
class MemberCantPlay extends AppEvent {
  final String name;
  final String error;
  const MemberCantPlay(this.name, this.error);
}

/// This member passes the video on slower than it plays.
class SlowSource extends AppEvent {
  final String text;
  const SlowSource(this.text);
}

/// This member started passing the video on through the server.
class RelayStarted extends AppEvent {
  const RelayStarted();
}

class RelayFailed extends AppEvent {
  final String error;
  const RelayFailed(this.error);
}

/// The connection to the server dropped and stayed down a few seconds
/// (once per drop).
class ConnectionLost extends AppEvent {
  const ConnectionLost();
}

/// It came back after [ConnectionLost].
class ConnectionBack extends AppEvent {
  const ConnectionBack();
}

/// The server refused something this app sent (`err`: Up next is full, a
/// forbidden action...).
class ServerRefused extends AppEvent {
  final String text;
  const ServerRefused(this.text);
}

/// The member passing the current video on has been gone a few seconds
/// ([left]: it left the server); viewers play what the server has.
class RelaySourceDropped extends AppEvent {
  final String name;
  final bool left;
  const RelaySourceDropped(this.name, {this.left = false});
}

/// The current media started playing for the first time ("starting
/// now"; [title]: what plays, '' when unknown).
class PlaybackStarted extends AppEvent {
  final String title;
  const PlaybackStarted(this.title);
}

/// A reconnect found the server restarted (another `welcome.instance`).
class ServerRestarted extends AppEvent {
  const ServerRestarted();
}

/// Another window of this install took the member over (`replaced`).
class Replaced extends AppEvent {
  const Replaced();
}

/// Jellyfin progress reports fail (once per media).
class JellyfinProgressFailed extends AppEvent {
  final bool signInExpired;
  const JellyfinProgressFailed({required this.signInExpired});
}

// ------------------------------------------------------------------ app

/// The player's shader message (a preset change, shaders turned off).
class ShaderMessage extends AppEvent {
  final String text;
  const ShaderMessage(this.text);
}

/// This app added an item to Up next.
class AddedToUpNext extends AppEvent {
  final String title;
  const AddedToUpNext(this.title);
}

/// Putting something up or adding it to Up next failed ([text]: why).
class ActionFailed extends AppEvent {
  final String text;
  const ActionFailed(this.text);
}

/// The Schedule tab's request results and errors.
class ScheduleResult extends AppEvent {
  final String text;
  const ScheduleResult(this.text);
}

/// "Mark a problem" done; [inSession]: in the server's session log.
class ProblemMarked extends AppEvent {
  final bool inSession;
  const ProblemMarked({required this.inSession});
}

/// Something went on the clipboard ([text]: the confirmation, e.g.
/// "Link copied").
class Copied extends AppEvent {
  final String text;
  const Copied(this.text);
}

class CopyFailed extends AppEvent {
  const CopyFailed();
}

/// A screenshot was saved and copied ([text] says what worked); its
/// toast shows [picture] (a small PNG) and a click on it runs [onEdit].
class ScreenshotTaken extends AppEvent {
  final String text;
  final Uint8List picture;
  final void Function()? onEdit;
  const ScreenshotTaken(this.text, this.picture, {this.onEdit});
}

/// A newer release is out (the update band shows it).
class UpdateAvailable extends AppEvent {
  final String version;
  const UpdateAvailable(this.version);
}
