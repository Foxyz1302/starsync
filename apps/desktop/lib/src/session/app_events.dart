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
  const FeedEvent(this.feed);

  String get actor => feed.actor;

  /// [feed] as its typed event. [selfName]: this member's name (the feed
  /// names members by name); [readyCount]: members ready in the latest
  /// state (the pitch of a `ready` sound).
  factory FeedEvent.of(FeedMessage f, {String? selfName, int readyCount = 0}) => switch (f.action) {
        'join' => MemberJoined(f),
        'leave' => MemberLeft(f),
        'stale' => MemberStale(f),
        'out' => MemberSatOut(f, atYou: f.target != null && f.target == selfName && f.actor != selfName),
        'back' => MemberBack(f),
        'ready' => ReadyChanged(f, ready: true, readyIndex: readyCount),
        'unready' => ReadyChanged(f, ready: false),
        'force-ready' => ForcedReady(f, ready: true),
        'force-unready' => ForcedReady(f, ready: false),
        'force-play' => ForcedTransport(f, play: true),
        'force-hold' => ForcedTransport(f, play: false),
        'swap' => MediaSwapped(f),
        'seek' => Seeked(f),
        'pause' => Paused(f),
        'resume' => Resumed(f),
        'finished' => Finished(f),
        'chat' => ChatPosted(f, own: f.actor == selfName),
        'rename' => MemberRenamed(f),
        'avatar' => AvatarChanged(f),
        'queue-add' => QueueAdded(f),
        'queue-remove' => QueueRemoved(f),
        'queue-skip' => QueueSkipped(f),
        'fetch-fail' => FetchFailed(f),
        _ => OtherFeed(f),
      };
}

class MemberJoined extends FeedEvent {
  const MemberJoined(super.feed);
}

class MemberLeft extends FeedEvent {
  const MemberLeft(super.feed);
}

class MemberStale extends FeedEvent {
  const MemberStale(super.feed);
}

/// Someone sat out (`target` sat out by `actor`); [atYou]: someone else
/// sat this member out.
class MemberSatOut extends FeedEvent {
  final bool atYou;
  const MemberSatOut(super.feed, {this.atYou = false});
}

class MemberBack extends FeedEvent {
  const MemberBack(super.feed);
}

class ReadyChanged extends FeedEvent {
  final bool ready;
  /// Members ready when it came (pitch of the ready sound).
  final int readyIndex;
  const ReadyChanged(super.feed, {required this.ready, this.readyIndex = 0});
}

class ForcedReady extends FeedEvent {
  final bool ready;
  const ForcedReady(super.feed, {required this.ready});
}

/// Force play / hold.
class ForcedTransport extends FeedEvent {
  final bool play;
  const ForcedTransport(super.feed, {required this.play});
}

class MediaSwapped extends FeedEvent {
  const MediaSwapped(super.feed);
}

class Seeked extends FeedEvent {
  const Seeked(super.feed);
}

class Paused extends FeedEvent {
  const Paused(super.feed);
}

class Resumed extends FeedEvent {
  const Resumed(super.feed);
}

class Finished extends FeedEvent {
  const Finished(super.feed);
}

/// A chat message (`reason` carries the text); [own]: this member sent it.
class ChatPosted extends FeedEvent {
  final bool own;
  const ChatPosted(super.feed, {this.own = false});
}

class MemberRenamed extends FeedEvent {
  const MemberRenamed(super.feed);
}

class AvatarChanged extends FeedEvent {
  const AvatarChanged(super.feed);
}

class QueueAdded extends FeedEvent {
  const QueueAdded(super.feed);
}

class QueueRemoved extends FeedEvent {
  const QueueRemoved(super.feed);
}

/// Up next skipped an item (`target` its title, `reason` why).
class QueueSkipped extends FeedEvent {
  const QueueSkipped(super.feed);
}

/// The server could not fetch the current media.
class FetchFailed extends FeedEvent {
  const FetchFailed(super.feed);
}

/// An action this app does not know (a newer server).
class OtherFeed extends FeedEvent {
  const OtherFeed(super.feed);
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

/// Idle: auto-unready (or sit-out, [sitsOut]) in 2 minutes.
class IdleWarning extends AppEvent {
  final bool sitsOut;
  const IdleWarning({required this.sitsOut});
}

/// The connection to the server dropped (once per drop).
class ConnectionLost extends AppEvent {
  const ConnectionLost();
}

/// It came back after [ConnectionLost].
class ConnectionBack extends AppEvent {
  const ConnectionBack();
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

/// A newer release is out (the update band shows it).
class UpdateAvailable extends AppEvent {
  final String version;
  const UpdateAvailable(this.version);
}
