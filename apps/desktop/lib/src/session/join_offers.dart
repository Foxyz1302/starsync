import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:signals/signals.dart';

import '../screens/home/health_probe.dart';
import '../state/connect_prefs.dart';
import 'invite.dart';
import 'navigation.dart';
import 'your_server.dart';

/// Where a join prompt came from.
enum OfferSource {
  /// A clicked `starsync://` link (this app started with it, or a second
  /// start handed it over).
  link,

  /// An invite found on the clipboard when the window came up.
  clipboard,
}

/// A server the app offers to join: "Join Bob's server (1.2.3.4:8080)?".
class JoinOffer {
  final InviteLink link;
  final OfferSource source;

  /// Its `/health` once read (name, version gate); null while asking.
  final ServerHealth? health;
  const JoinOffer(this.link, this.source, {this.health});

  JoinOffer withHealth(ServerHealth h) => JoinOffer(link, source, health: h);

  /// The server's own name (`/health`), else the link's, else ''.
  String get name {
    final own = health?.label ?? '';
    return own.isNotEmpty ? own : link.name;
  }

  /// "Join Bob's server (1.2.3.4:8080)?"
  String get question => name.isEmpty ? 'Join ${link.address}?' : 'Join $name (${link.address})?';

  /// What `/health` said, in plain words: '' while asking.
  String get detail {
    final h = health;
    if (h == null) return '';
    if (!h.online) return "Can't reach it right now";
    if (h.needsUpdate) return versionGateText(h);
    return [
      if (h.version.isNotEmpty) 'Starsync ${h.version}',
      if (h.viewers > 0) '${h.viewers} watching',
    ].join(' · ');
  }
}

/// A fingerprint of [link] (password included) for "already asked": the
/// link itself is never stored.
String inviteFingerprint(InviteLink link) =>
    sha256.convert(utf8.encode('starsync-invite:${link.uri}')).toString().substring(0, 24);

/// The join prompt: a clicked invite link, or one found on the
/// clipboard, becomes an [offer] (`Join <name> (host:port)?`) with the
/// server's `/health`; [accept] hands back what to join, [dismiss] drops
/// it. A clipboard invite is offered once: joined or dismissed, the same
/// link is not offered again (a fingerprint is kept, never the link).
/// Links to your own server, or to the one you are in, are not offered.
/// Nothing here logs what the clipboard holds. Made by the composition
/// root.
class JoinOffers {
  JoinOffers({required this.navigation, required this.yourServer, required this.forms});

  final Navigation navigation;
  final YourServer yourServer;
  final ConnectStore forms;

  final offer = signal<JoinOffer?>(null);

  /// The clipboard text last looked at (its hash): the same text is not
  /// parsed twice in a row.
  int? _lastClip;

  /// The app's start arguments, or a second start's: the first
  /// `starsync://` link among them becomes an offer.
  void fromArgs(List<String> args) {
    for (final a in args) {
      final link = InviteLink.parse(a);
      if (link != null) {
        _offer(link, OfferSource.link);
        return;
      }
    }
  }

  /// The clipboard's text when the window came up ([text] null: none).
  void fromClipboard(String? text) {
    if (text == null || text.isEmpty) return;
    final h = text.hashCode;
    if (h == _lastClip) return;
    _lastClip = h;
    final link = inviteIn(text);
    if (link == null || forms.seenInvite(inviteFingerprint(link))) return;
    _offer(link, OfferSource.clipboard);
  }

  /// This app put [text] on the clipboard (Copy invite): never offered
  /// back to it.
  void copied(String text) => _lastClip = text.hashCode;

  void _offer(InviteLink link, OfferSource source) {
    if (yourServer.isOwn(link)) return;
    if (navigation.place.peek() == Place.friend && navigation.address.peek() == '${link.host}:${link.port}') return;
    final current = offer.peek();
    if (current != null && current.link == link) return;
    final o = JoinOffer(link, source);
    offer.value = o;
    unawaited(probeHealth(link.host, '${link.port}', navigation.healthGet).then((h) {
      if (identical(offer.peek(), o)) offer.value = o.withHealth(h);
    }));
  }

  /// Not now: a clipboard invite is not offered again.
  Future<void> dismiss() async {
    final o = offer.peek();
    if (o == null) return;
    offer.value = null;
    if (o.source == OfferSource.clipboard) await forms.rememberInvite(inviteFingerprint(o.link));
  }

  /// Join: the link to join (its password, else the one saved for that
  /// recent server); the invite is not offered again. Null when there
  /// was none.
  InviteLink? accept() {
    final o = offer.peek();
    if (o == null) return null;
    offer.value = null;
    unawaited(forms.rememberInvite(inviteFingerprint(o.link)));
    final l = o.link;
    if (l.secret.isNotEmpty) return l;
    return InviteLink(host: l.host, port: l.port, name: l.name, secret: forms.secretFor(l.host, l.port));
  }
}
