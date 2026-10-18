import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// The URL scheme of an invite link ([InviteLink]).
const inviteScheme = 'starsync';

/// The port a link without one means (the app's default sharing port).
const defaultInvitePort = 8080;

/// What a friend needs to join your server: where ([host], [port]), what
/// it is called ([name]), whether it asks a password ([password]; the
/// password itself is never in it) and which Starsync runs it
/// ([version]). [fp]: reserved for a pinned certificate fingerprint
/// (`wss://` with a self-signed certificate); always null for now.
class Invite {
  final String host;
  final int port;
  final String name;
  final bool password;
  final String version;
  final String? fp;
  const Invite({
    required this.host,
    required this.port,
    this.name = '',
    this.password = false,
    this.version = '',
    this.fp,
  });

  /// What goes in the Join card's address and port.
  String get address => '${host.contains(':') ? '[$host]' : host}:$port';

  /// The same invite at another of this machine's addresses.
  Invite at(String host) =>
      Invite(host: host, port: port, name: name, password: password, version: version, fp: fp);

  /// Its `starsync://` link; the password only when given ([secret]).
  InviteLink link({String secret = ''}) => InviteLink(host: host, port: port, name: name, secret: secret);

  /// The text Invite copies: the link, whether to ask for the password
  /// (not when [secret] puts it in the link), the version to match.
  String textWith({String secret = ''}) => [
        'Join me on Starsync: ${link(secret: secret).uri}',
        if (password && secret.isEmpty) '(ask me for the password)',
        if (version.isNotEmpty) '· Starsync $version',
      ].join(' ');

  /// [textWith] without the password.
  String get text => textWith();

  @override
  bool operator ==(Object other) =>
      other is Invite &&
      other.host == host &&
      other.port == port &&
      other.name == name &&
      other.password == password &&
      other.version == version &&
      other.fp == fp;

  @override
  int get hashCode => Object.hash(host, port, name, password, version, fp);

  @override
  String toString() => 'Invite($address${password ? ', password' : ''})';
}

/// A `starsync://host:port/?name=…&pw=…` invite link (PROTOCOL.md "Invite
/// link"): where to join, the server's name for the prompt, and the
/// password when the host chose to put it in. [toString] never shows the
/// password; [uri] does.
class InviteLink {
  final String host;
  final int port;
  final String name;
  final String secret;
  const InviteLink({required this.host, required this.port, this.name = '', this.secret = ''});

  String get address => '${host.contains(':') ? '[$host]' : host}:$port';

  /// One per server (for "already asked about this one").
  String get key => '${host.toLowerCase()}:$port';

  /// The link itself (with the password, when it has one).
  String get uri {
    final query = [
      if (name.isNotEmpty) 'name=${Uri.encodeQueryComponent(name)}',
      if (secret.isNotEmpty) 'pw=${Uri.encodeQueryComponent(secret)}',
    ];
    return '$inviteScheme://$address${query.isEmpty ? '' : '/?${query.join('&')}'}';
  }

  /// Null unless [text] is a `starsync://` link with a host and a usable
  /// port (none means [defaultInvitePort]).
  static InviteLink? parse(String text) {
    final t = text.trim();
    if (!t.toLowerCase().startsWith('$inviteScheme://')) return null;
    final Uri u;
    try {
      u = Uri.parse(t);
    } catch (_) {
      return null;
    }
    final host = u.host.trim();
    if (host.isEmpty || !_hostChars.hasMatch(host)) return null;
    final port = u.hasPort ? u.port : defaultInvitePort;
    if (port <= 0 || port > 65535) return null;
    final Map<String, String> q;
    try {
      q = u.queryParameters;
    } catch (_) {
      return null;
    }
    return InviteLink(host: host, port: port, name: _cleanName(q['name'] ?? ''), secret: q['pw'] ?? '');
  }

  @override
  bool operator ==(Object other) =>
      other is InviteLink && other.host == host && other.port == port && other.name == name && other.secret == secret;

  @override
  int get hashCode => Object.hash(host, port, name, secret);

  @override
  String toString() => 'InviteLink($address${secret.isEmpty ? '' : ', password'})';
}

final _hostChars = RegExp(r'^[A-Za-z0-9.:-]+$');
final _control = RegExp(r'[\x00-\x1f\x7f]');

/// A link's name as shown in the prompt: no control characters, at most
/// 64 characters.
String _cleanName(String raw) {
  final n = raw.replaceAll(_control, '').trim();
  return n.length > 64 ? n.substring(0, 64) : n;
}

final _linkIn = RegExp('$inviteScheme://[^\\s<>"\'`]+', caseSensitive: false);
final _plainInvite = RegExp(r'Join me on Starsync:\s*(\S+)');

/// Only the start of a long text is searched (a clipboard can hold a book).
const _searchLimit = 4096;

/// The invite in [text]: a `starsync://` link anywhere in it, else the
/// address of a plain invite ("Join me on Starsync: 192.168.1.20:8080",
/// what 1.3.x copied). Null for anything else, a bare address included.
InviteLink? inviteIn(String text) {
  final t = text.length > _searchLimit ? text.substring(0, _searchLimit) : text;
  final m = _linkIn.firstMatch(t);
  if (m != null) return InviteLink.parse(m[0]!);
  final plain = _plainInvite.firstMatch(t);
  if (plain == null) return null;
  final a = addressIn(plain[1]!);
  final port = a == null ? null : int.tryParse(a.port);
  if (a == null || port == null || port <= 0 || port > 65535) return null;
  return InviteLink(host: a.host, port: port);
}

/// The `host:port` in a pasted invite (or a bare address); null when
/// there is none.
({String host, String port})? addressIn(String text) {
  final m = RegExp(r'(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):(\d{1,5})\b').firstMatch(text);
  if (m == null) return null;
  final host = m.group(1)!;
  return (host: host.startsWith('[') ? host.substring(1, host.length - 1) : host, port: m.group(2)!);
}

/// Interface names of container and VM bridges, never a way in for a
/// friend (Docker, Podman, libvirt, LXC, VirtualBox, VMware, WSL/Hyper-V).
final _virtualName = RegExp(
    r'^(docker|br-|veth|virbr|vmnet|vboxnet|cni|flannel|podman|lxcbr|lxdbr|vEthernet|VirtualBox|VMware)',
    caseSensitive: false);

/// The proxy fake-IP range (198.18.0.0/15, benchmarking space that TUN
/// proxies like Clash hand out): this machine's address on it is useless
/// to anyone else.
bool isFakeIp(List<int> b) => b[0] == 198 && (b[1] == 18 || b[1] == 19);

bool _isPrivate(List<int> b) =>
    b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] < 32);

/// Shared address space (100.64.0.0/10): mesh VPNs like Tailscale (and
/// carrier-grade NAT).
bool _isShared(List<int> b) => b[0] == 100 && b[1] >= 64 && b[1] < 128;

/// Where an invite address works.
enum AddressKind {
  /// The internet: anyone, when the port is open to them.
  public,

  /// The same home network.
  lan,

  /// A mesh VPN (Tailscale and the like): everyone on it.
  vpn,
}

/// [AddressKind] of an IPv4 address.
AddressKind addressKind(String ip) {
  final a = InternetAddress.tryParse(ip);
  if (a == null || a.type != InternetAddressType.IPv4) return AddressKind.public;
  final b = a.rawAddress;
  if (_isPrivate(b)) return AddressKind.lan;
  if (_isShared(b)) return AddressKind.vpn;
  return AddressKind.public;
}

/// [ip] is an IPv4 address the internet routes to this network: not
/// private, shared, loopback, link-local, fake-IP, multicast or
/// reserved (the documentation ranges pass: tests use them).
bool isPublicIpv4(String ip) {
  final a = InternetAddress.tryParse(ip.trim());
  if (a == null || a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return !(b[0] == 0 ||
      b[0] == 127 ||
      b[0] >= 224 ||
      (b[0] == 169 && b[1] == 254) ||
      _isPrivate(b) ||
      _isShared(b) ||
      isFakeIp(b));
}

/// The addresses of [interfaces] a friend could dial, best first: IPv4,
/// no loopback, link-local or fake-IP address, no container or VM bridge;
/// home networks (192.168, then 10, then 172.16/12) first, then a mesh
/// VPN's, then anything else (a public address). No repeats.
List<String> inviteAddresses(Iterable<({String name, InternetAddress address})> interfaces) {
  int rank(List<int> b) => b[0] == 192 && b[1] == 168
      ? 0
      : _isPrivate(b)
          ? 1
          : _isShared(b)
              ? 2
              : 3;
  final usable = [
    for (final i in interfaces)
      if (i.address.type == InternetAddressType.IPv4 &&
          !i.address.isLoopback &&
          !i.address.isLinkLocal &&
          !(i.address.rawAddress[0] == 169 && i.address.rawAddress[1] == 254) &&
          !isFakeIp(i.address.rawAddress) &&
          !_virtualName.hasMatch(i.name))
        i.address,
  ];
  final indexed = [for (var n = 0; n < usable.length; n++) (n, usable[n])];
  indexed.sort((a, b) {
    final r = rank(a.$2.rawAddress).compareTo(rank(b.$2.rawAddress));
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return {for (final (_, a) in indexed) a.address}.toList();
}

/// One address an invite can carry and where it works.
typedef InviteAddress = ({String host, AddressKind kind});

/// What the members card offers for a shared server: the internet
/// address first when known ([public], from [lookUpPublicAddress]), then
/// this machine's own ([local], [inviteAddresses] order). [forwarding]:
/// the internet address is the router's, not this machine's, so friends
/// elsewhere get in only when the port is forwarded to it.
class InviteReach {
  final String? public;
  final List<String> local;
  /// The internet lookup is still under way.
  final bool looking;
  const InviteReach({this.public, this.local = const [], this.looking = false});

  bool get forwarding => public != null && !local.contains(public);

  /// Every address, best first, each once: the internet one, then this
  /// machine's.
  List<InviteAddress> get choices => [
        if (public != null) (host: public!, kind: AddressKind.public),
        for (final l in local)
          if (l != public) (host: l, kind: addressKind(l)),
      ];

  /// The address an invite carries unless the user picks another: the
  /// internet one when known, else the best of this machine's.
  String? get best => choices.firstOrNull?.host;
}

/// This machine's interfaces as [inviteAddresses] takes them (empty when
/// they can't be listed).
Future<List<({String name, InternetAddress address})>> machineInterfaces() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in list)
        for (final a in i.addresses) (name: i.name, address: a),
    ];
  } catch (e) {
    debugPrint('list network interfaces failed: $e');
    return const [];
  }
}
