import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/picked_media.dart';
import 'accounts.dart';
import 'format.dart';
import '../library/media_refs.dart';

// Jellyfin media in a session: turning picks and pasted links into refs
// (the wire carries only `{serverId, itemId, ...}`), the hosted server's
// relay credential, and how this viewer plays a ref (own account, relay,
// or neither).

/// The wire ref of a browser pick.
JellyfinRef refForPick(JellyfinMedia m) => JellyfinRef(
      serverId: m.serverId,
      itemId: m.itemId,
      mediaSourceId: m.mediaSourceId,
      title: m.title,
      subtitle: m.subtitle.isEmpty ? null : m.subtitle,
      runtimeSecs: m.runtime == null ? null : m.runtime!.inMilliseconds / 1000,
    );

/// The `swap` media for a browser pick: a ref, never a URL.
HelloMedia mediaForPick(JellyfinMedia m) => HelloMedia(
    name: m.title.isEmpty ? 'Jellyfin item' : m.title,
    size: 0,
    duration: 0,
    jellyfin: refForPick(m),
    ref: m.ref ?? jellyfinPickRef(m.title, m.subtitle));

/// The pick a ref stands for on a linked server (for highlighting it in
/// the browser); null when this install has no account there.
JellyfinMedia? pickForRef(JellyfinAccounts accounts, JellyfinRef ref) {
  final a = accounts.account(ref.serverId);
  if (a == null) return null;
  return JellyfinMedia(
    serverId: ref.serverId,
    baseUrl: a.baseUrl,
    itemId: ref.itemId,
    mediaSourceId: ref.mediaSourceId,
    title: ref.title,
    subtitle: ref.subtitle ?? '',
    runtime: ref.runtimeSecs == null
        ? null
        : Duration(milliseconds: (ref.runtimeSecs! * 1000).round()),
  );
}

/// The ref in a `state.media` map, or null for other media.
JellyfinRef? refOfStateMedia(Map<String, Object?>? media) {
  final jf = media?['jellyfin'];
  if (jf is! Map) return null;
  try {
    final ref = JellyfinRef.fromJson(Map<String, Object?>.from(jf));
    return ref.serverId.isEmpty || ref.itemId.isEmpty ? null : ref;
  } catch (_) {
    return null;
  }
}

/// Same item (server, item, source); titles may differ.
bool sameJellyfinItem(JellyfinRef? a, JellyfinRef? b) =>
    a != null &&
    b != null &&
    a.serverId == b.serverId &&
    a.itemId == b.itemId &&
    a.mediaSourceId == b.mediaSourceId;

final _sourceId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// What a pasted link becomes on the wire. A recognised Jellyfin item link
/// (`parseJellyfinLink`) becomes a ref when its ServerId is known (in the
/// link or from `/System/Info/Public`); its `api_key` is never shared then.
/// Anything else, or a server that does not answer, stays a plain link.
/// The title comes from this install's account on that server when there
/// is one.
Future<HelloMedia> mediaForLink(JellyfinAccounts accounts, String url,
    {Duration timeout = const Duration(seconds: 6)}) async {
  final name = linkName(url);
  final plain = HelloMedia(name: name, size: 0, duration: 0, url: url, ref: linkMediaRef(name));
  final link = parseJellyfinLink(url);
  if (link == null) return plain;
  await accounts.ensureLoaded();
  var serverId = link.serverId;
  if (serverId == null || serverId.isEmpty) {
    final probe = accounts.anonymousClient(link.baseUrl);
    try {
      serverId = (await probe.publicInfo().timeout(timeout)).id;
    } catch (e) {
      debugPrint('jellyfin link: no server id from ${link.baseUrl}: $e');
      return plain;
    } finally {
      probe.close();
    }
    if (serverId.isEmpty) return plain;
  }
  final src = Uri.tryParse(url)?.queryParameters['mediaSourceId'];
  var ref = JellyfinRef(
    serverId: serverId,
    itemId: link.itemId,
    mediaSourceId: src != null && _sourceId.hasMatch(src) && src != link.itemId ? src : null,
  );
  final account = accounts.account(serverId);
  final client = accounts.clientFor(serverId);
  MediaRef? what;
  if (account != null && client != null) {
    try {
      final pick = pickFor(account, await client.item(link.itemId).timeout(timeout));
      what = pick.ref;
      ref = refForPick(JellyfinMedia(
        serverId: serverId,
        baseUrl: account.baseUrl,
        itemId: link.itemId,
        mediaSourceId: ref.mediaSourceId,
        title: pick.title,
        subtitle: pick.subtitle,
        runtime: pick.runtime,
      ));
    } catch (e) {
      if (e is JellyfinException && e.isUnauthorized) accounts.markExpired(serverId);
    }
  }
  return HelloMedia(
      name: ref.title.isEmpty ? 'Jellyfin item' : ref.title,
      size: 0,
      duration: 0,
      jellyfin: ref,
      ref: what ?? jellyfinPickRef(ref.title, ref.subtitle ?? ''));
}

/// Display name for a link: last path segment, decoded, never the query
/// (Jellyfin-style links carry api_key there and names are broadcast).
String linkName(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return 'link';
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isNotEmpty) {
    try {
      return Uri.decodeComponent(segs.last);
    } catch (_) {
      return segs.last;
    }
  }
  return uri.host.isNotEmpty ? uri.host : 'link';
}

/// The hosted server's relay logins: one per linked Jellyfin account
/// whose token is not known to be expired (the default account first),
/// so `/j` relays an item with its own server's login. The device fields
/// are exactly the ones this app sends with those tokens
/// ([JellyfinAccounts.clientInfo]): Jellyfin rewrites a token's device
/// from the request header, so the relay must not differ.
List<JellyfinCredential> relayCredentialsFor(JellyfinAccounts accounts) {
  final info = accounts.clientInfo;
  final first = accounts.defaultAccount;
  return [
    for (final a in [?first, ...accounts.accounts.where((a) => a.serverId != first?.serverId)])
      if (accounts.statusOf(a.serverId) != JellyfinAccountStatus.expired)
        JellyfinCredential(
          baseUrl: a.baseUrl,
          serverId: a.serverId,
          token: a.token,
          client: info.client,
          device: info.device,
          deviceId: info.deviceId,
          version: info.version,
        ),
  ];
}

/// `/j/...` URL of the current Jellyfin media on the host this client
/// dialled, built like the `/m/...` one.
String relayUrlFor(String host, int port, String token, String itemId) =>
    'http://$host:$port/j/default/$token/${Uri.encodeComponent(itemId)}';

// ---------------------------------------------------------------- playing

/// How this viewer plays a ref.
sealed class JellyfinPlan {
  const JellyfinPlan();

  /// `report.jf` for this plan; null when it plays nothing.
  bool? get jfAccess;
}

/// Direct play with this install's account: the static stream, the token
/// in [headers] (not in the URL), progress reported per [info].
final class OwnPlay extends JellyfinPlan {
  final JellyfinClient client;
  final JellyfinAccount account;
  final JellyfinPlaybackInfo info;
  final JellyfinMediaSource source;
  /// Full item (series, episode numbers); null if that call failed.
  final JellyfinItem? item;
  final String url;
  final Map<String, String> headers;
  const OwnPlay({
    required this.client,
    required this.account,
    required this.info,
    required this.source,
    required this.item,
    required this.url,
    required this.headers,
  });

  @override
  bool get jfAccess => true;
}

/// Through the server: its own Jellyfin login (`/j/...`) or the member
/// who put it up (`/r/...`).
final class RelayPlay extends JellyfinPlan {
  final String url;
  const RelayPlay(this.url);

  @override
  bool get jfAccess => false;
}

/// Neither: no (usable) account here and nothing relays it.
final class BlockedPlay extends JellyfinPlan {
  final String serverId;
  /// Known only when this install has (had) an account there.
  final String? serverName;
  /// Why the own account did not work, if there is one.
  final String? problem;
  const BlockedPlay({required this.serverId, this.serverName, this.problem});

  @override
  bool? get jfAccess => null;

  String get message {
    final where = serverName == null || serverName!.isEmpty ? 'that Jellyfin server' : serverName!;
    final base = 'No Jellyfin account here for $where, and nobody is passing it on';
    return problem == null ? base : '$base ($problem)';
  }
}

/// Picks how to play [ref]: this install's account first (PlaybackInfo
/// with its own user; a 401 marks the account expired), else the server's
/// own Jellyfin login ([relay] = `state.relay`, [relayUrl] this member's
/// `/j/...` URL), else the member who put it up ([memberRelayUrl], the
/// `/r/...` URL when `media.relay` is set), else [BlockedPlay].
Future<JellyfinPlan> resolveJellyfinRef(
  JellyfinAccounts accounts,
  JellyfinRef ref, {
  required bool relay,
  required String? relayUrl,
  String? memberRelayUrl,
  Duration timeout = const Duration(seconds: 15),
}) async {
  await accounts.ensureLoaded();
  final account = accounts.account(ref.serverId);
  String? problem;
  if (account != null && accounts.statusOf(ref.serverId) == JellyfinAccountStatus.expired) {
    problem = 'your sign-in expired, reconnect it in Integrations';
  } else if (account != null) {
    final client = accounts.clientFor(ref.serverId)!;
    try {
      final infoF = client.playbackInfo(ref.itemId, mediaSourceId: ref.mediaSourceId).timeout(timeout);
      final itemF = client
          .item(ref.itemId)
          .timeout(timeout)
          .then<JellyfinItem?>((i) => i, onError: (Object _) => null);
      final info = await infoF;
      final item = await itemF;
      final source = (ref.mediaSourceId == null
              ? null
              : info.mediaSources.where((s) => s.id == ref.mediaSourceId).firstOrNull) ??
          info.primarySource;
      if (source == null) throw const JellyfinException('no playable source');
      return OwnPlay(
        client: client,
        account: account,
        info: info,
        source: source,
        item: item,
        url: client.shareableStreamUrl(ref.itemId, mediaSourceId: source.id).toString(),
        headers: client.authHeaders,
      );
    } catch (e) {
      debugPrint('jellyfin resolve ${ref.itemId} with own account failed: $e');
      if (e is JellyfinException && e.isUnauthorized) {
        accounts.markExpired(ref.serverId);
        problem = 'your sign-in expired, reconnect it in Integrations';
      } else if (e is JellyfinException && e.statusCode == 404) {
        problem = 'your account cannot see this item';
      } else {
        problem = 'could not reach it';
      }
    }
  }
  if (relay && relayUrl != null && relayUrl.isNotEmpty) return RelayPlay(relayUrl);
  if (memberRelayUrl != null && memberRelayUrl.isNotEmpty) return RelayPlay(memberRelayUrl);
  return BlockedPlay(serverId: ref.serverId, serverName: account?.displayName, problem: problem);
}

// ------------------------------------------------------------ next episode

/// A neighbouring episode as this viewer can put it up.
class EpisodeLink {
  final JellyfinItem item;
  final JellyfinMedia pick;
  const EpisodeLink(this.item, this.pick);

  /// "S1E7 Battle with the Heroes".
  String get label => [?item.episodeLabel, item.name].join(' ');
}

/// The episodes before and after the one [plan] plays, with its account.
/// Both null for movies, at the ends of a series, or on failure.
Future<({EpisodeLink? previous, EpisodeLink? next})> findAdjacentEpisodes(OwnPlay plan,
    {Duration timeout = const Duration(seconds: 15)}) async {
  const none = (previous: null, next: null);
  final item = plan.item;
  if (item == null || item.kind != JellyfinItemKind.episode || item.seriesId == null) return none;
  try {
    final around = await plan.client.adjacentEpisodes(item).timeout(timeout);
    EpisodeLink? link(JellyfinItem? i) => i == null ? null : EpisodeLink(i, pickFor(plan.account, i));
    return (previous: link(around.previous), next: link(around.next));
  } catch (e) {
    debugPrint('episode lookup failed: $e');
    return none;
  }
}

/// Where the "Next episode" pill's window starts: at [endingStart] (the
/// ED: Jellyfin Outro segment or ED-titled chapter, see `endingRange`)
/// when one is known inside [runtime], else the last two minutes of
/// [runtime] (all of it for shorter media). The pill shows only while the
/// controls are up (`PillGate`), so a guessed window costs nothing.
Duration nextPromptStart(JellyfinItem? item, Duration runtime, {Duration? endingStart}) {
  if (endingStart != null && endingStart > Duration.zero && endingStart < runtime) {
    return endingStart;
  }
  const lead = Duration(minutes: 2);
  return runtime > lead ? runtime - lead : Duration.zero;
}
