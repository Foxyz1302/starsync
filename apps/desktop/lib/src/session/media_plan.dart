import 'package:sync_relay_core/core.dart';

import '../jellyfin/session_media.dart' show refOfStateMedia, relayUrlFor;
import 'delivery.dart' show stateMediaRelay;
import 'party.dart' show isPresent;

// The plan step of the media pipeline: from the server's state, what this
// member serves, its own capabilities and who is present, where this app
// reads the current media from. One switch, pure: `media_plan_test` holds
// the table.

/// What this member serves for the media it put up (set at its swap,
/// claimed by the state that names it as the relay's source).
sealed class MediaOrigin {
  const MediaOrigin();
}

/// A file on this computer, passed on through the relay.
final class FileOrigin extends MediaOrigin {
  final String path;
  const FileOrigin(this.path);
}

/// A link this computer reads and passes on ("through me").
final class LinkOrigin extends MediaOrigin {
  final String url;

  /// What the link is (a page goes through [ytDlp]).
  final LinkProbe probe;
  final YtDlp ytDlp;
  const LinkOrigin(this.url, this.probe, this.ytDlp);
}

/// A Jellyfin item: served with this install's account, else with the
/// pasted [link] (its api_key stays on this machine).
final class JellyfinOrigin extends MediaOrigin {
  final String? link;
  const JellyfinOrigin(this.link);
}

/// Where this app's server is, as this member dialled it.
class ServerAddress {
  final String host;
  final int port;
  final String token;
  const ServerAddress(this.host, this.port, this.token);

  /// This viewer's `/m` URL of your server's file [name].
  String fileUrl(String name) => 'http://$host:$port/m/default/$token/${Uri.encodeComponent(name)}';

  /// This viewer's `/r` URL of a relay ([key]: the media id, or the queue
  /// id of one started in Up next); with tracks, a pieces playlist or an
  /// mpv EDL of every track.
  String relayUrl(String name, String key, [List<RelayTrackSpec> tracks = const []]) =>
      relayViewerUrl('http://$host:$port/r/default/$token/$key', name, tracks: tracks);

  /// This member's `/j` URL of [ref] (the server's Jellyfin login).
  String jellyfinUrl(JellyfinRef ref) => relayUrlFor(host, port, token, ref.itemId);

  /// The relay channel this member feeds ([queueId]: the warm relay of
  /// that Up next item).
  Uri sourceChannel([String queueId = '']) => Uri.parse('ws://$host:$port/r/default/$token/source'
      '${queueId.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(queueId)}'}');
}

/// Where this app reads the current media from.
sealed class SourcePlan {
  const SourcePlan();

  /// The URL a player opens; null when there is nothing to open yet.
  String? get url => null;
}

/// No media, or nothing this app can open (yet).
final class NoSource extends SourcePlan {
  const NoSource();
}

/// This member passes its file on: the player plays the file itself, the
/// relay source feeds the server.
final class OwnFile extends SourcePlan {
  final String path;
  const OwnFile(this.path);
  @override
  String get url => path;
}

/// This member passes a link on: it plays the link itself (a page through
/// its yt-dlp), the relay source reads it for the server.
final class OwnLink extends SourcePlan {
  @override
  final String url;
  final LinkOrigin origin;
  const OwnLink(this.url, this.origin);
}

/// Your server's own file (`/m`).
final class ServerFile extends SourcePlan {
  @override
  final String url;
  const ServerFile(this.url);
}

/// A link everyone opens itself; [page]: a web page, resolved by this
/// app's yt-dlp (the pipeline's resolve step).
final class DirectLink extends SourcePlan {
  @override
  final String url;
  final bool page;
  const DirectLink(this.url, {required this.page});
}

/// The server's relay (`/r`): a member passing it on ([sourceId]) or the
/// server's own fetch ([fetch]). [waiting]: nobody feeds it yet, so it opens
/// once `relay.live` (mpv gives up on a silent request after 5 s).
final class RelayedSource extends SourcePlan {
  @override
  final String url;
  final bool fetch;
  final String sourceId;
  final bool waiting;
  const RelayedSource(this.url, {required this.fetch, required this.sourceId, required this.waiting});
}

/// A Jellyfin item: this app's own account first ([ownAccount]), then the
/// server's login ([serverLogin], `/j`), then the member who put it up
/// ([memberRelay], `/r`); the resolve step decides. [origin]: this member
/// put it up (it passes it on to viewers without an account).
final class JellyfinSource extends SourcePlan {
  final JellyfinRef ref;
  final bool ownAccount;
  final String? serverLogin;
  final String? memberRelay;
  final JellyfinOrigin? origin;
  const JellyfinSource(this.ref, {required this.ownAccount, this.serverLogin, this.memberRelay, this.origin});
}

/// A page link this app cannot resolve (no yt-dlp here: `caps.resolve`
/// false): [via] names who can pass it on.
final class Unresolvable extends SourcePlan {
  final String link;
  final String via;
  const Unresolvable(this.link, this.via);

  String get reason => "This device can't open web pages; ${via.isEmpty ? 'ask someone' : via} to pass it on (Through me)";
}

/// What [planMedia] reads.
class PlanInput {
  final StateBroadcast state;
  final String selfId;
  final ClientCaps caps;
  final ServerAddress server;

  /// What this member serves for [StateBroadcast.mediaId] (null: nothing).
  final MediaOrigin? origin;

  /// This app plays Jellyfin [serverId] with its own account.
  final bool Function(String serverId) ownJellyfin;
  const PlanInput({
    required this.state,
    required this.selfId,
    required this.caps,
    required this.server,
    this.origin,
    required this.ownJellyfin,
  });
}

/// A relay nobody feeds yet: the server's fetch before it is read, or a
/// member's before its channel is up while that member is still here
/// (once it is gone or left, the server's buffer is all there is: open
/// that).
bool relayWaitsForSource(StateBroadcast r, MediaRelay relay) =>
    !relay.live && !relay.sourceGone && (relay.fetch || r.members.any((m) => m.id == relay.source));

/// The members that can resolve a page link (`caps.resolve`), present
/// ones, lowest id first.
List<MemberView> linkResolvers(StateBroadcast r, {String except = ''}) =>
    [for (final m in r.members) if (m.caps.resolve && isPresent(m) && m.id != except) m];

/// Where this app reads [input]'s media from.
SourcePlan planMedia(PlanInput input) {
  final r = input.state;
  final media = r.media;
  if (media == null) return const NoSource();
  final name = (media['name'] as String?) ?? '';
  final relay = stateMediaRelay(r);
  final mine = relay != null && relay.source.isNotEmpty && relay.source == input.selfId;
  final origin = mine ? input.origin : null;
  final key = relay == null || relay.queueId.isEmpty ? '${r.mediaId}' : relay.queueId;

  final ref = refOfStateMedia(media);
  if (ref != null) {
    return JellyfinSource(
      ref,
      ownAccount: input.ownJellyfin(ref.serverId),
      serverLogin: r.relay && input.server.token.isNotEmpty ? input.server.jellyfinUrl(ref) : null,
      memberRelay: relay != null && !mine ? input.server.relayUrl(name, key) : null,
      origin: origin is JellyfinOrigin ? origin : (mine ? const JellyfinOrigin(null) : null),
    );
  }
  switch (origin) {
    case FileOrigin(:final path):
      return OwnFile(path);
    case LinkOrigin(:final url):
      return OwnLink(url, origin);
    case JellyfinOrigin() || null:
      break;
  }
  if (relay != null) {
    // Another member's relay or the server's fetch; this member's own
    // relay without its origin (a restarted app) reads the server's buffer.
    return RelayedSource(input.server.relayUrl(name, key, relay.tracks),
        fetch: relay.fetch, sourceId: relay.source, waiting: !mine && relayWaitsForSource(r, relay));
  }
  final url = media['url'];
  if (url is String && url.isNotEmpty) {
    final uri = Uri.tryParse(url);
    final web = uri != null && (uri.isScheme('http') || uri.isScheme('https'));
    final page = web && !hasMediaExtension(uri);
    if (page && !input.caps.resolve) {
      final who = linkResolvers(r, except: input.selfId).firstOrNull;
      return Unresolvable(url, who == null ? '' : 'ask ${who.name}');
    }
    return DirectLink(url, page: page);
  }
  if (name.isNotEmpty && input.server.token.isNotEmpty) return ServerFile(input.server.fileUrl(name));
  return const NoSource();
}
